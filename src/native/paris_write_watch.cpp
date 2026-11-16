#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "scheduler.hpp"
#include "command.hpp"
#include "console/console.hpp"
#include <utils/flags.hpp>
#include <utils/hook.hpp>
#include <TlHelp32.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <thread>

// Write watch for lab clients (-paris-write-watch [<targets>]; compiled with -Perf): names the code that writes a qword of the client's memory.
//
// Why: an owner crash (16 Nov 2026, iw7_ship.exe+0x8CA8E2) read the vtable qword of element 0 of the hit-result array of the client's cg object
// (cg + 0x74278, the constructor writes 0x141440EE0 there; no stock path stores 0) and found 0. A dump without the heap cannot say who wrote the 0.
//
// What it does, per target (up to four, each 1, 2, 4 or 8 bytes, aligned):
//  1. A hardware data breakpoint (DR0-DR3, write) on every thread of the process. A helper thread suspends a thread, writes the debug registers with
//     SetThreadContext and resumes it (nothing is allocated or locked while a thread is suspended). The helper looks for new threads every 100 ms and reads
//     the registers of every thread back every -paris-write-watch-sweep ms (default 2000): a thread whose registers were reset is counted ("[WW] lost") and armed again.
//     The target address is evaluated again every 50 ms (cg moves at every map load) and all threads are re-armed when it changes. A slot that a thread already uses
//     for another address is never taken: another free slot is used, or the target is refused for that thread (counted).
//  2. A vectored exception handler (first in the chain) that answers only EXCEPTION_SINGLE_STEP with one of our addresses in a set DR6 bit. It reads the value
//     (old = the last value seen, new = now), and unless the new value is the expected one (or -paris-write-watch-all) it stores a record in a lock-free ring:
//     thread, RIP, registers, the 16 bytes before RIP, a stack unwind (RtlVirtualUnwind) and a scan of the stack for return addresses after a call.
//     It never allocates, logs or takes a lock. A data breakpoint traps AFTER the store: RIP is the instruction that follows it (inside memset or memcpy for a block write, so the stack names the writer).
//  3. Records are written to iw7-mod/paris-write-watch/ww-<time>-<pid>.log by the helper thread (at once, durable) and printed with the [WW] prefix by the
//     main thread each frame.
//  4. Per-frame guard (backup when the registers are reset or never reach a thread): once a frame the main thread reads every target and logs the first frame it
//     differs from the expected value, with the frame number, the time and the last zone and weapon lines the console printed.
// Stats line every 60 s ([WW] stats): frames, guard cost per frame, helper cpu, threads armed, lost registers, traps, logged, writer threads.
//
// Nothing changes for a process started without the flag. Test commands (only with -paris-isolated-lab): paris_ww_test <scratch|scratch_thread|scratch_memset|real>.
namespace paris_write_watch
{
    namespace
    {
        // cg[local client] at 0x141FA6C88 holds scrambled pointers (a 16 Nov 2026 run read 0x4C48E77C436D0228 from it). The two allocations are plain:
        // FUN_140240A00 (Zombies / CP client) stores the base of its 0xFDEA8 byte objects in 0x141FDBEF0, FUN_1402B5000 (MP client) the base of its 0xD64C0 byte objects in 0x141FDCF50.
        constexpr std::uint64_t cg_cp_array = 0x141FDBEF0, cg_cp_stride = 0xFDEA8, cg_mp_array = 0x141FDCF50, cg_mp_stride = 0xD64C0;
        constexpr std::uint64_t game_base = 0x140000000;
        constexpr std::uint64_t hit_vtable = 0x141440EE0; // vtable the constructor FUN_140161D80 writes into each hit result
        constexpr std::uint64_t hit_offset = 0x74278;     // the hit-result array of cg
        constexpr std::uint64_t hit_stride = 0x350;
        constexpr int max_targets = 4, max_terms = 6;
        constexpr unsigned ring_size = 512, stack_depth = 16, scan_depth = 12, scan_qwords = 192, event_count = 32, event_len = 148, history_size = 64, writer_slots = 32;

        struct term { char kind; int sign; std::uint64_t value; }; // kind: n number, c cg object of local client `value`, g game base, d qword at the number, s scratch cell
        struct target
        {
            char name[96]{};
            term terms[max_terms]{};
            int term_count{};
            unsigned len{8};
            std::uint64_t expect{hit_vtable};
            bool any{};
            std::atomic<std::uint64_t> addr{0};      // resolved address, 0 while cg is not allocated
            std::atomic<std::uint64_t> shadow{0};    // the last value the trap saw
            std::atomic<std::uint64_t> traps{0}, logged{0};
            std::uint64_t guard_addr{}, guard_last{}; unsigned guard_logs{}; bool guard_seen{}; // main thread only
        };
        struct record
        {
            std::atomic<int> ready{0};
            std::uint64_t seq{}, qpc{}, tick{}, rip{}, rsp{}, addr{}, old_value{}, new_value{}, regs[8]{};
            unsigned tid{}, target_index{}, unwind_count{}, scan_count{};
            std::uint64_t unwind[stack_depth]{}, scan[scan_depth]{};
            unsigned char code[16]{};
        };
        struct event_line { std::uint64_t tick{}; char text[event_len]{}; };

        target targets[max_targets];
        int target_count{};
        bool enabled{}, use_hw{true}, use_guard{true}, main_only{}, log_all{};
        unsigned sweep_ms{2000};
        record ring[ring_size];
        std::atomic<unsigned> ring_head{0}, ring_dropped{0};
        unsigned printed{};              // main thread only: records printed to the console
        unsigned written{};              // helper thread only: records written to the file
        std::atomic<std::uint64_t> traps_total{0}, handler_ns{0}, handler_max_ns{0}, handler_untraced{0};
        std::atomic<std::uint64_t> history[history_size]; std::atomic<unsigned> history_count{0};
        struct writer_slot { std::atomic<unsigned> tid{0}; std::atomic<std::uint64_t> count{0}; };
        writer_slot writers[writer_slots];
        event_line events[event_count]; std::atomic<unsigned> event_head{0};
        std::atomic<unsigned> main_tid{0};
        std::atomic<bool> stop{false};
        std::thread helper;
        HANDLE helper_handle{};
        HANDLE log_file{INVALID_HANDLE_VALUE};
        PVOID veh{};
        std::int64_t qpc_hz{};
        std::uint64_t image_size{};
        alignas(64) volatile std::uint64_t scratch_cell[8];
        utils::hook::detour console_hook;
        std::string selftest_modes;                       // -paris-write-watch-selftest <modes>: the proof commands run by themselves (lab only)
        std::size_t selftest_next{};
        std::uint64_t selftest_due{};
        void run_test(const std::string& mode);

        // helper statistics
        std::atomic<std::uint64_t> sweeps{0}, scans{0}, armed_threads{0}, lost_total{0}, rearm_total{0}, refused_total{0}, suspend_failed{0}, known_threads{0};
        // main thread statistics
        std::uint64_t frames{}, guard_ns{}, guard_max_ns{}, first_tick{}, last_stats_tick{};

        std::int64_t qpc()
        {
            LARGE_INTEGER value{};
            QueryPerformanceCounter(&value);
            return value.QuadPart;
        }
        std::uint64_t to_ns(const std::int64_t counts) { return qpc_hz ? static_cast<std::uint64_t>(counts) * 1000000000ull / static_cast<std::uint64_t>(qpc_hz) : 0; }

        // ---- reading memory that may disappear -------------------------------------------------------------------------------------------------
        __declspec(noinline) bool read_bytes(const std::uint64_t address, void* destination, const std::size_t size) noexcept
        {
            __try { std::memcpy(destination, reinterpret_cast<const void*>(address), size); return true; }
            __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
        }
        bool read_value(const std::uint64_t address, const unsigned len, std::uint64_t& value) noexcept
        {
            value = 0;
            return read_bytes(address, &value, len);
        }

        std::atomic<int> cg_kind{0}; // 1: the CP array was used, 2: the MP array
        std::uint64_t image_end() noexcept { return game_base + (image_size ? image_size : 0x2000000); }
        // The object of local client `index`: the array base is plain, and the object's own vtable (the first qword) must be an address of the game image: the
        // object is zero before its constructor ran, so this also keeps the watch from arming while the block is being zero-filled and constructed.
        std::uint64_t cg_object(const std::uint64_t index) noexcept
        {
            static const struct { std::uint64_t array, stride; int kind; } arrays[2] = { { cg_cp_array, cg_cp_stride, 1 }, { cg_mp_array, cg_mp_stride, 2 } };
            for (const auto& a : arrays)
            {
                std::uint64_t base{}, vtable{};
                if (!read_bytes(a.array, &base, 8) || base < 0x10000 || base > 0x7FFFFFFEFFFFull) continue;
                const auto object = base + index * a.stride;
                if (!read_bytes(object, &vtable, 8) || vtable < game_base || vtable >= image_end()) continue;
                cg_kind.store(a.kind);
                return object;
            }
            return 0;
        }
        // The address must be committed, writable memory of the process (a wrong expression gives a garbage address, and a debug register refuses or truncates those).
        bool plausible_address(const std::uint64_t address, const unsigned len) noexcept
        {
            if (address < 0x10000 || address > 0x7FFFFFFEFFFFull) return false;
            MEMORY_BASIC_INFORMATION m{};
            if (!VirtualQuery(reinterpret_cast<const void*>(address), &m, sizeof(m)) || m.State != MEM_COMMIT || (m.Protect & (PAGE_GUARD | PAGE_NOACCESS))) return false;
            const auto p = m.Protect & 0xFF;
            if (p != PAGE_READWRITE && p != PAGE_WRITECOPY && p != PAGE_EXECUTE_READWRITE && p != PAGE_EXECUTE_WRITECOPY) return false;
            const auto base = reinterpret_cast<std::uint64_t>(m.BaseAddress);
            return address >= base && address + len <= base + m.RegionSize;
        }

        // ---- the address expression: terms of + and -: 0x74278, 1234, cg, cg1, game, [0x141FA6C88], scratch ------------------------------------------
        bool parse_number(const char* text, std::uint64_t& out)
        {
            char* end{};
            out = std::strtoull(text, &end, 0);
            return end != text && *end == 0;
        }
        bool parse_expression(const char* text, target& t)
        {
            t.term_count = 0;
            int sign = 1;
            const char* p = text;
            while (*p)
            {
                char token[48]{};
                unsigned n = 0;
                if (*p == '[')
                {
                    while (*p && *p != ']' && n < sizeof(token) - 2) token[n++] = *p++;
                    if (*p != ']') return false;
                    token[n++] = *p++;
                }
                else while (*p && *p != '+' && *p != '-' && n < sizeof(token) - 1) token[n++] = *p++;
                if (!n || t.term_count >= max_terms) return false;
                term x{'n', sign, 0};
                if (token[0] == '[')
                {
                    token[n - 1] = 0;
                    if (!parse_number(token + 1, x.value)) return false;
                    x.kind = 'd';
                }
                else if (!std::strncmp(token, "cg", 2) && (!token[2] || (token[2] >= '0' && token[2] <= '7' && !token[3])))
                {
                    x.kind = 'c'; x.value = token[2] ? static_cast<std::uint64_t>(token[2] - '0') : 0;
                }
                else if (!std::strcmp(token, "game")) x.kind = 'g';
                else if (!std::strcmp(token, "scratch")) x.kind = 's';
                else if (!parse_number(token, x.value)) return false;
                t.terms[t.term_count++] = x;
                if (*p == '+') { sign = 1; ++p; }
                else if (*p == '-') { sign = -1; ++p; }
            }
            return t.term_count > 0;
        }
        std::uint64_t evaluate(const target& t) noexcept
        {
            std::uint64_t sum = 0;
            for (int i = 0; i < t.term_count; ++i)
            {
                const auto& x = t.terms[i];
                std::uint64_t v = 0;
                switch (x.kind)
                {
                case 'n': v = x.value; break;
                case 'g': v = game_base; break;
                case 's': v = reinterpret_cast<std::uint64_t>(&scratch_cell[0]); break;
                case 'c': v = cg_object(x.value); if (!v) return 0; break;
                case 'd': if (!read_bytes(x.value, &v, 8) || v < 0x10000) return 0; break;
                default: return 0;
                }
                sum += x.sign > 0 ? v : static_cast<std::uint64_t>(0) - v;
            }
            return sum;
        }

        // ---- command line ----------------------------------------------------------------------------------------------------------------------
        bool argument(const wchar_t* name, std::wstring& value)
        {
            int count{};
            auto* args = CommandLineToArgvW(GetCommandLineW(), &count);
            if (!args) return false;
            bool found = false;
            for (int i = 1; i < count; ++i)
            {
                if (_wcsicmp(args[i], name)) continue;
                found = true;
                value.clear();
                if (i + 1 < count && args[i + 1][0] != L'-' && args[i + 1][0] != L'+') value = args[i + 1];
                break;
            }
            LocalFree(args);
            return found;
        }
        unsigned number_argument(const wchar_t* name, const unsigned fallback)
        {
            std::wstring value;
            if (!argument(name, value) || value.empty()) return fallback;
            return static_cast<unsigned>(_wtoi(value.c_str()));
        }
        bool add_target(const char* spec)
        {
            if (target_count >= max_targets) return false;
            auto& t = targets[target_count];
            char text[160]{};
            strcpy_s(text, spec);
            strncpy_s(t.name, spec, _TRUNCATE);
            t.len = 8; t.expect = hit_vtable; t.any = false;
            if (auto* colon = std::strchr(text, ':')) { *colon = 0; t.len = static_cast<unsigned>(std::atoi(colon + 1)); }
            if (auto* equals = std::strchr(text, '='))
            {
                *equals = 0;
                if (!std::strcmp(equals + 1, "any")) t.any = true;
                else if (!parse_number(equals + 1, t.expect)) return false;
            }
            if (t.len != 1 && t.len != 2 && t.len != 4 && t.len != 8) return false;
            if (!parse_expression(text, t)) return false;
            ++target_count;
            return true;
        }
        bool add_preset_or_target(const std::string& item)
        {
            if (item == "hitresult") return add_target("cg+0x74278=0x141440EE0:8");
            if (item == "hitresult4")
            {
                for (unsigned i = 0; i < 4; ++i)
                {
                    char spec[96]{};
                    std::snprintf(spec, sizeof(spec), "cg+0x%llX=0x141440EE0:8", static_cast<unsigned long long>(hit_offset + i * hit_stride));
                    if (!add_target(spec)) return false;
                }
                return true;
            }
            if (item == "scratch") return add_target("scratch=0x141440EE0:8");
            return add_target(item.c_str());
        }

        // ---- the debug registers of one thread --------------------------------------------------------------------------------------------------
        bool in_history(const std::uint64_t address) noexcept
        {
            const auto n = history_count.load(std::memory_order_acquire);
            for (unsigned i = 0; i < n && i < history_size; ++i) if (history[i].load(std::memory_order_relaxed) == address) return true;
            return false;
        }
        void remember(const std::uint64_t address)
        {
            if (!address || in_history(address)) return;
            const auto i = history_count.load();
            if (i >= history_size) return;
            history[i].store(address, std::memory_order_relaxed);
            history_count.store(i + 1, std::memory_order_release);
        }
        bool slot_enabled(const std::uint64_t ctl7, const int slot) noexcept { return (ctl7 >> (2 * slot)) & 3; }
        unsigned len_bits(const unsigned len) noexcept { return len == 1 ? 0u : len == 2 ? 1u : len == 4 ? 3u : 2u; }
        bool slot_matches(const std::uint64_t ctl7, const std::uint64_t reg, const int slot, const std::uint64_t address, const unsigned len) noexcept
        {
            if (!(ctl7 & (1ull << (2 * slot))) || reg != address) return false;
            return ((ctl7 >> (16 + 4 * slot)) & 3) == 1 && ((ctl7 >> (18 + 4 * slot)) & 3) == len_bits(len);
        }
        enum class arm_result { ok, rearmed, lost, refused, failed };

        // Suspend, read the registers, write them when they differ, resume. Nothing is allocated or locked between SuspendThread and ResumeThread.
        // `verify`: a thread that was armed before and now differs is reported as lost.
        arm_result apply_thread(const DWORD tid, const bool verify, unsigned& refused_here)
        {
            const HANDLE handle = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_SET_CONTEXT | THREAD_QUERY_LIMITED_INFORMATION, FALSE, tid);
            if (!handle) return arm_result::failed;
            alignas(16) CONTEXT c{};
            c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
            arm_result result = arm_result::failed;
            std::uint64_t want_addr[max_targets]{};
            unsigned want_len[max_targets]{};
            for (int i = 0; i < target_count; ++i) { want_addr[i] = use_hw ? targets[i].addr.load() : 0; want_len[i] = targets[i].len; }
            if (SuspendThread(handle) != static_cast<DWORD>(-1))
            {
                if (GetThreadContext(handle, &c))
                {
                    std::uint64_t* dr[4] = { &c.Dr0, &c.Dr1, &c.Dr2, &c.Dr3 };
                    std::uint64_t ctl7 = c.Dr7;
                    bool changed = false, any_missing = false;
                    refused_here = 0;
                    for (int s = 0; s < 4; ++s) // free the slots that hold an address of ours that is not a target any more
                    {
                        if (!slot_enabled(ctl7, s) || (*dr[s] && !in_history(*dr[s]))) continue; // a slot of someone else is never touched; an enabled slot at address 0 is junk
                        bool current = false;
                        for (int i = 0; i < target_count; ++i) if (want_addr[i] == *dr[s]) current = true;
                        if (current) continue;
                        ctl7 &= ~((3ull << (2 * s)) | (0xFull << (16 + 4 * s))); *dr[s] = 0; changed = true; any_missing = true;
                    }
                    bool claimed[4]{};
                    for (int i = 0; i < target_count; ++i)
                    {
                        if (!want_addr[i]) continue;
                        int slot = -1;
                        for (int s = 0; s < 4 && slot < 0; ++s) if (!claimed[s] && slot_matches(ctl7, *dr[s], s, want_addr[i], want_len[i])) slot = s;
                        if (slot >= 0) { claimed[slot] = true; continue; }
                        any_missing = true;
                        for (int s = 0; s < 4 && slot < 0; ++s) if (!claimed[s] && !slot_enabled(ctl7, s)) slot = s;
                        if (slot < 0) { ++refused_here; continue; } // every slot is in use by someone else
                        claimed[slot] = true;
                        *dr[slot] = want_addr[i];
                        ctl7 &= ~((3ull << (2 * slot)) | (0xFull << (16 + 4 * slot)));
                        ctl7 |= (1ull << (2 * slot)) | (1ull << (16 + 4 * slot)) | (static_cast<std::uint64_t>(len_bits(want_len[i])) << (18 + 4 * slot));
                        changed = true;
                    }
                    if (changed)
                    {
                        c.Dr7 = ctl7; c.Dr6 = 0; c.ContextFlags = CONTEXT_DEBUG_REGISTERS;
                        result = SetThreadContext(handle, &c) ? (any_missing && verify ? arm_result::lost : arm_result::rearmed) : arm_result::failed;
                    }
                    else result = arm_result::ok;
                    if (refused_here && result != arm_result::failed) result = arm_result::refused;
                }
                ResumeThread(handle);
            }
            else suspend_failed.fetch_add(1);
            CloseHandle(handle);
            return result;
        }

        // ---- the vectored handler ----------------------------------------------------------------------------------------------------------------
        __declspec(noinline) unsigned unwind_stack(const CONTEXT& start, std::uint64_t* out, const unsigned max) noexcept
        {
            unsigned n = 0;
            __try
            {
                CONTEXT c = start;
                for (; n < max; ++n)
                {
                    DWORD64 base{};
                    UNWIND_HISTORY_TABLE history_table{};
                    const auto* entry = RtlLookupFunctionEntry(c.Rip, &base, &history_table);
                    if (!entry)
                    {
                        if (!c.Rsp) break;
                        c.Rip = *reinterpret_cast<const std::uint64_t*>(c.Rsp); c.Rsp += 8;
                    }
                    else
                    {
                        PVOID handler_data{}; DWORD64 frame{};
                        RtlVirtualUnwind(UNW_FLAG_NHANDLER, base, c.Rip, const_cast<PRUNTIME_FUNCTION>(entry), &c, &handler_data, &frame, nullptr);
                    }
                    if (!c.Rip) break;
                    out[n] = c.Rip;
                }
            }
            __except (EXCEPTION_EXECUTE_HANDLER) {}
            return n;
        }
        bool after_call(const std::uint64_t address) noexcept
        {
            unsigned char b[8]{};
            if (!read_bytes(address - 8, b, 8)) return false;
            // b[8 - k] is the byte k before the return address
            return b[3] == 0xE8                                                // call rel32
                || (b[2] == 0xFF && b[3] == 0x15)                              // call [rip+rel32]
                || (b[2] == 0xFF && (b[3] & 0xF8) == 0x90)                     // call [reg+disp32]
                || (b[5] == 0xFF && (b[6] & 0xF8) == 0x50)                     // call [reg+disp8]
                || (b[6] == 0xFF && (b[7] & 0xF8) == 0xD0);                    // call reg
        }
        __declspec(noinline) unsigned scan_stack(const std::uint64_t stack_pointer, std::uint64_t* out, const unsigned max) noexcept
        {
            unsigned n = 0;
            for (unsigned i = 0; i < scan_qwords && n < max; ++i)
            {
                std::uint64_t value{};
                if (!read_bytes(stack_pointer + 8ull * i, &value, 8)) break;
                if (value > game_base + 16 && value < game_base + image_size && after_call(value)) out[n++] = value;
            }
            return n;
        }
        void note_writer(const unsigned tid) noexcept
        {
            for (unsigned i = 0; i < writer_slots; ++i)
            {
                unsigned expected = 0;
                if (writers[i].tid.load(std::memory_order_relaxed) == tid || writers[i].tid.compare_exchange_strong(expected, tid))
                {
                    writers[i].count.fetch_add(1);
                    return;
                }
            }
        }
        LONG CALLBACK handler(EXCEPTION_POINTERS* info)
        {
            if (!info || !info->ExceptionRecord || info->ExceptionRecord->ExceptionCode != EXCEPTION_SINGLE_STEP || !info->ContextRecord) return EXCEPTION_CONTINUE_SEARCH;
            auto& c = *info->ContextRecord;
            if (!(c.ContextFlags & CONTEXT_DEBUG_REGISTERS)) return EXCEPTION_CONTINUE_SEARCH;
            const unsigned bits = static_cast<unsigned>(c.Dr6 & 0xF);
            if (!bits || !enabled) return EXCEPTION_CONTINUE_SEARCH;
            const std::uint64_t* dr[4] = { &c.Dr0, &c.Dr1, &c.Dr2, &c.Dr3 };
            const auto t0 = qpc();
            bool ours = false;
            for (int s = 0; s < 4; ++s)
            {
                if (!(bits & (1u << s))) continue;
                const auto address = *dr[s];
                if (!in_history(address)) continue;
                ours = true;
                c.Dr6 &= ~(1ull << s);
                int index = -1;
                for (int i = 0; i < target_count; ++i) if (targets[i].addr.load(std::memory_order_relaxed) == address) index = i;
                if (index < 0) continue; // a stale register of a target that moved: swallowed, the helper corrects the thread
                auto& t = targets[index];
                std::uint64_t value{};
                read_value(address, t.len, value);
                const auto old_value = t.shadow.exchange(value);
                t.traps.fetch_add(1); traps_total.fetch_add(1);
                note_writer(GetCurrentThreadId());
                if (!log_all && !t.any && value == t.expect) continue;
                const auto slot = ring_head.fetch_add(1);
                if (slot >= ring_size) { ring_dropped.fetch_add(1); continue; }
                auto& r = ring[slot];
                r.seq = slot; r.qpc = static_cast<std::uint64_t>(qpc()); r.tick = GetTickCount64(); r.rip = c.Rip; r.rsp = c.Rsp; r.addr = address;
                r.old_value = old_value; r.new_value = value; r.tid = GetCurrentThreadId(); r.target_index = static_cast<unsigned>(index);
                r.regs[0] = c.Rax; r.regs[1] = c.Rcx; r.regs[2] = c.Rdx; r.regs[3] = c.Rbx; r.regs[4] = c.Rsi; r.regs[5] = c.Rdi; r.regs[6] = c.R8; r.regs[7] = c.R9;
                std::memset(r.code, 0, sizeof(r.code));
                read_bytes(c.Rip - 16, r.code, 16);
                r.unwind_count = unwind_stack(c, r.unwind, stack_depth);
                r.scan_count = scan_stack(c.Rsp, r.scan, scan_depth);
                t.logged.fetch_add(1);
                r.ready.store(1, std::memory_order_release);
            }
            if (!ours) return EXCEPTION_CONTINUE_SEARCH;
            const auto dt = to_ns(qpc() - t0);
            handler_ns.fetch_add(dt);
            auto previous = handler_max_ns.load();
            while (dt > previous && !handler_max_ns.compare_exchange_weak(previous, dt)) {}
            return EXCEPTION_CONTINUE_EXECUTION;
        }

        // ---- text of a record ----------------------------------------------------------------------------------------------------------------------
        void locate(const std::uint64_t address, char* out, const std::size_t size)
        {
            if (address >= game_base && address < game_base + image_size) { std::snprintf(out, size, "game+0x%llX", static_cast<unsigned long long>(address - game_base)); return; }
            MEMORY_BASIC_INFORMATION m{};
            if (VirtualQuery(reinterpret_cast<const void*>(address), &m, sizeof(m)) && m.AllocationBase && m.Type == MEM_IMAGE)
            {
                char path[MAX_PATH]{};
                if (GetModuleFileNameA(static_cast<HMODULE>(m.AllocationBase), path, MAX_PATH))
                {
                    const char* name = std::strrchr(path, '\\');
                    std::snprintf(out, size, "%s+0x%llX", name ? name + 1 : path, static_cast<unsigned long long>(address - reinterpret_cast<std::uint64_t>(m.AllocationBase)));
                    return;
                }
            }
            std::snprintf(out, size, "0x%llX", static_cast<unsigned long long>(address));
        }
        void thread_label(const unsigned tid, char* out, const std::size_t size)
        {
            if (tid == main_tid.load()) { std::snprintf(out, size, "%u(main)", tid); return; }
            using get_description = HRESULT(WINAPI*)(HANDLE, PWSTR*);
            static const auto fn = reinterpret_cast<get_description>(GetProcAddress(GetModuleHandleA("kernelbase.dll"), "GetThreadDescription"));
            const HANDLE h = fn ? OpenThread(THREAD_QUERY_LIMITED_INFORMATION, FALSE, tid) : nullptr;
            if (h)
            {
                PWSTR text{};
                if (SUCCEEDED(fn(h, &text)) && text)
                {
                    char narrow[48]{};
                    WideCharToMultiByte(CP_UTF8, 0, text, -1, narrow, sizeof(narrow) - 1, nullptr, nullptr);
                    LocalFree(text);
                    CloseHandle(h);
                    if (narrow[0]) { std::snprintf(out, size, "%u(%s)", tid, narrow); return; }
                }
                else CloseHandle(h);
            }
            std::snprintf(out, size, "%u", tid);
        }
        void format_record(const record& r, std::string& out)
        {
            char buffer[640]{}, place[96]{}, label[80]{};
            locate(r.rip, place, sizeof(place));
            thread_label(r.tid, label, sizeof(label));
            std::snprintf(buffer, sizeof(buffer), "[WW] hit #%llu target=%s addr=0x%llX tid=%s rip=%s (the store is the instruction BEFORE rip) old=0x%llX new=0x%llX tick=%llu\n",
                static_cast<unsigned long long>(r.seq), targets[r.target_index].name, static_cast<unsigned long long>(r.addr), label, place,
                static_cast<unsigned long long>(r.old_value), static_cast<unsigned long long>(r.new_value), static_cast<unsigned long long>(r.tick));
            out += buffer;
            std::snprintf(buffer, sizeof(buffer), "[WW]   regs rax=%llX rcx=%llX rdx=%llX rbx=%llX rsi=%llX rdi=%llX r8=%llX r9=%llX rsp=%llX\n",
                static_cast<unsigned long long>(r.regs[0]), static_cast<unsigned long long>(r.regs[1]), static_cast<unsigned long long>(r.regs[2]), static_cast<unsigned long long>(r.regs[3]),
                static_cast<unsigned long long>(r.regs[4]), static_cast<unsigned long long>(r.regs[5]), static_cast<unsigned long long>(r.regs[6]), static_cast<unsigned long long>(r.regs[7]),
                static_cast<unsigned long long>(r.rsp));
            out += buffer;
            std::string bytes;
            for (auto b : r.code) { char x[4]; std::snprintf(x, sizeof(x), "%02X ", b); bytes += x; }
            out += "[WW]   16 bytes before rip: " + bytes + "\n";
            out += "[WW]   unwind:";
            for (unsigned i = 0; i < r.unwind_count; ++i) { locate(r.unwind[i], place, sizeof(place)); out += " "; out += place; }
            out += "\n[WW]   stack scan (return addresses after a call):";
            for (unsigned i = 0; i < r.scan_count; ++i) { locate(r.scan[i], place, sizeof(place)); out += " "; out += place; }
            out += "\n";
        }
        void write_file(const std::string& text)
        {
            if (log_file == INVALID_HANDLE_VALUE || text.empty()) return;
            DWORD done{};
            WriteFile(log_file, text.data(), static_cast<DWORD>(text.size()), &done, nullptr);
        }
        void print_console(const std::string& text)
        {
            std::size_t start = 0;
            while (start < text.size())
            {
                auto end = text.find('\n', start);
                if (end == std::string::npos) end = text.size();
                console::info("%.*s\n", static_cast<int>(end - start), text.data() + start);
                start = end + 1;
            }
        }
        std::string recent_events(const unsigned count)
        {
            std::string out;
            const auto head = event_head.load();
            const unsigned have = head < event_count ? head : event_count;
            const unsigned take = count < have ? count : have;
            for (unsigned i = take; i > 0; --i)
            {
                const auto& e = events[(head - i) % event_count];
                char line[event_len + 48]{};
                std::snprintf(line, sizeof(line), "[WW]   event t=%llu ms: %s\n", static_cast<unsigned long long>(e.tick - first_tick), e.text);
                out += line;
            }
            return out;
        }

        // ---- the helper thread ---------------------------------------------------------------------------------------------------------------------
        void drain_to_file()
        {
            const auto head = ring_head.load();
            const unsigned limit = head < ring_size ? head : ring_size;
            while (written < limit)
            {
                auto& r = ring[written];
                if (!r.ready.load(std::memory_order_acquire)) break;
                std::string text;
                format_record(r, text);
                write_file(text);
                ++written;
            }
        }
        void helper_main()
        {
            struct known { DWORD tid; std::uint64_t generation; std::uint64_t retry_at; };
            static known threads[512];
            unsigned thread_count = 0;
            std::uint64_t generation = 1, last_addr[max_targets]{}, last_invalid[max_targets]{}, last_scan = 0, last_sweep = GetTickCount64();
            while (!stop.load())
            {
                Sleep(50);
                bool moved = false;
                for (int i = 0; i < target_count; ++i)
                {
                    auto now_addr = evaluate(targets[i]);
                    if (now_addr && (!plausible_address(now_addr, targets[i].len) || (now_addr & (targets[i].len - 1))))
                    {
                        if (now_addr != last_invalid[i])
                        {
                            last_invalid[i] = now_addr;
                            char line[220]{};
                            std::snprintf(line, sizeof(line), "[WW] target %s evaluates to 0x%llX: not committed writable memory or not aligned, not armed\n", targets[i].name, static_cast<unsigned long long>(now_addr));
                            write_file(line);
                            refused_total.fetch_add(1);
                        }
                        now_addr = 0;
                    }
                    if (now_addr == last_addr[i]) continue;
                    if (now_addr) { remember(now_addr); std::uint64_t v{}; read_value(now_addr, targets[i].len, v); targets[i].shadow.store(v); }
                    targets[i].addr.store(now_addr);
                    last_addr[i] = now_addr;
                    moved = true;
                    char line[200]{};
                    std::snprintf(line, sizeof(line), "[WW] target %s now at 0x%llX (value 0x%llX, cg array %s)\n", targets[i].name, static_cast<unsigned long long>(now_addr), static_cast<unsigned long long>(targets[i].shadow.load()), cg_kind.load() == 1 ? "CP" : cg_kind.load() == 2 ? "MP" : "none");
                    write_file(line);
                }
                if (moved) { ++generation; rearm_total.fetch_add(1); }
                drain_to_file();
                bool any_resolved = false;
                for (int i = 0; i < target_count; ++i) any_resolved = any_resolved || targets[i].addr.load() != 0;
                const auto now = GetTickCount64();
                // look for new threads; arm what is new or out of date
                if (use_hw && (any_resolved || thread_count) && (moved || now - last_scan >= 100))
                {
                    last_scan = now;
                    scans.fetch_add(1);
                    DWORD seen[512]; unsigned seen_count = 0;
                    const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
                    if (snapshot != INVALID_HANDLE_VALUE)
                    {
                        THREADENTRY32 e{}; e.dwSize = sizeof(e);
                        const DWORD pid = GetCurrentProcessId(), self = GetCurrentThreadId();
                        for (BOOL ok = Thread32First(snapshot, &e); ok; ok = Thread32Next(snapshot, &e))
                            if (e.th32OwnerProcessID == pid && e.th32ThreadID != self && seen_count < 512 && (!main_only || e.th32ThreadID == main_tid.load())) seen[seen_count++] = e.th32ThreadID;
                        CloseHandle(snapshot);
                    }
                    // drop the threads that ended
                    for (unsigned i = 0; i < thread_count;)
                    {
                        bool alive = false;
                        for (unsigned j = 0; j < seen_count; ++j) if (seen[j] == threads[i].tid) alive = true;
                        if (alive) ++i; else threads[i] = threads[--thread_count];
                    }
                    const bool sweep = now - last_sweep >= sweep_ms;
                    if (sweep) { last_sweep = now; sweeps.fetch_add(1); }
                    for (unsigned j = 0; j < seen_count; ++j)
                    {
                        known* k = nullptr;
                        for (unsigned i = 0; i < thread_count; ++i) if (threads[i].tid == seen[j]) k = &threads[i];
                        const bool is_new = !k;
                        if (is_new && thread_count < 512) { threads[thread_count] = { seen[j], 0, 0 }; k = &threads[thread_count++]; }
                        if (!k) continue;
                        if (!is_new && k->generation == generation && !sweep) continue;
                        if (now < k->retry_at) continue;
                        unsigned refused_here = 0;
                        const bool was_armed = k->generation != 0;
                        const auto result = apply_thread(k->tid, sweep && was_armed && k->generation == generation, refused_here);
                        if (result == arm_result::failed) { k->retry_at = now + 2000; continue; } // exited or protected: tried again in 2 s
                        k->generation = generation;
                        if (result == arm_result::lost)
                        {
                            lost_total.fetch_add(1);
                            char line[160]{}, label[80]{};
                            thread_label(k->tid, label, sizeof(label));
                            std::snprintf(line, sizeof(line), "[WW] lost: the debug registers of thread %s were reset, armed again (total %llu)\n", label, static_cast<unsigned long long>(lost_total.load()));
                            write_file(line);
                        }
                        if (result == arm_result::refused) refused_total.fetch_add(1);
                    }
                    known_threads.store(thread_count);
                    std::uint64_t armed = 0;
                    armed = thread_count;
                    armed_threads.store(armed);
                }
            }
            // disarm every thread before the handler could go away: targets off, one more pass
            for (int i = 0; i < target_count; ++i) targets[i].addr.store(0);
            const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
            if (snapshot != INVALID_HANDLE_VALUE)
            {
                THREADENTRY32 e{}; e.dwSize = sizeof(e);
                const DWORD pid = GetCurrentProcessId(), self = GetCurrentThreadId();
                for (BOOL ok = Thread32First(snapshot, &e); ok; ok = Thread32Next(snapshot, &e))
                    if (e.th32OwnerProcessID == pid && e.th32ThreadID != self) { unsigned r = 0; apply_thread(e.th32ThreadID, false, r); }
                CloseHandle(snapshot);
            }
            drain_to_file();
        }

        // ---- the main thread: guard, console lines, statistics -----------------------------------------------------------------------------------
        bool interesting(const std::string& message)
        {
            if (message.size() > 4 && message[0] == '[' && message[1] == 'W' && message[2] == 'W') return false;
            const auto size = message.size() < 200 ? message.size() : 200;
            for (std::size_t i = 0; i + 4 < size; ++i)
            {
                const char a = static_cast<char>(message[i] | 0x20);
                if (a == 'z' && (message[i + 1] | 0x20) == 'o' && (message[i + 2] | 0x20) == 'n' && (message[i + 3] | 0x20) == 'e') return true;
                if (a == 'w' && (message[i + 1] | 0x20) == 'e' && (message[i + 2] | 0x20) == 'a' && (message[i + 3] | 0x20) == 'p' && (message[i + 4] | 0x20) == 'o') return true;
            }
            return false;
        }
        void add_event(const char* text, const std::size_t size)
        {
            auto& e = events[event_head.fetch_add(1) % event_count];
            e.tick = GetTickCount64();
            std::size_t n = size < event_len - 1 ? size : event_len - 1;
            while (n && (text[n - 1] == '\n' || text[n - 1] == '\r')) --n;
            std::memcpy(e.text, text, n);
            e.text[n] = 0;
        }
        void console_stub(int type, const std::string& message)
        {
            if (enabled && interesting(message)) add_event(message.data(), message.size());
            console_hook.invoke<void, int, const std::string*>(type, &message);
        }
        void frame()
        {
            const auto t0 = qpc();
            if (!main_tid.load()) { main_tid.store(GetCurrentThreadId()); last_stats_tick = GetTickCount64(); }
            ++frames;
            if (use_guard)
            {
                for (int i = 0; i < target_count; ++i)
                {
                    auto& t = targets[i];
                    auto address = evaluate(t);
                    if (address && !plausible_address(address, t.len)) address = 0;
                    if (address != t.guard_addr) { t.guard_addr = address; t.guard_seen = false; }
                    if (!address) continue;
                    std::uint64_t value{};
                    if (!read_value(address, t.len, value)) continue;
                    if (!t.guard_seen) { t.guard_seen = true; t.guard_last = value; continue; }
                    if (value == t.guard_last) continue;
                    const bool bad_before = !t.any && t.guard_last != t.expect, bad_now = !t.any && value != t.expect;
                    const auto before = t.guard_last;
                    t.guard_last = value;
                    if ((!log_all && !t.any && !bad_before && !bad_now) || t.guard_logs >= 20) continue;
                    ++t.guard_logs;
                    char line[256]{};
                    std::snprintf(line, sizeof(line), "[WW] guard: target %s changed at frame %llu, %llu ms after start, 0x%llX -> 0x%llX (expected 0x%llX), main thread %u; hardware hits so far %llu\n",
                        t.name, static_cast<unsigned long long>(frames), static_cast<unsigned long long>(GetTickCount64() - first_tick), static_cast<unsigned long long>(before),
                        static_cast<unsigned long long>(value), static_cast<unsigned long long>(t.expect), GetCurrentThreadId(), static_cast<unsigned long long>(t.logged.load()));
                    std::string text = line + recent_events(8);
                    write_file(text);
                    print_console(text);
                }
            }
            if (!selftest_modes.empty() && selftest_next < selftest_modes.size())
            {
                const auto now_ms = GetTickCount64();
                if (!selftest_due) selftest_due = now_ms + 15000; // the helper needs a moment to arm every thread
                else if (now_ms >= selftest_due)
                {
                    auto end = selftest_modes.find(',', selftest_next);
                    if (end == std::string::npos) end = selftest_modes.size();
                    const auto mode = selftest_modes.substr(selftest_next, end - selftest_next);
                    bool ready_to_run = true;
                    if (mode == "real") { ready_to_run = false; for (int i = 0; i < target_count; ++i) if (targets[i].terms[0].kind == 'c' && targets[i].addr.load()) ready_to_run = true; }
                    if (ready_to_run) { run_test(mode); selftest_next = end + 1; selftest_due = now_ms + 3000; }
                    else selftest_due = now_ms + 1000;
                    if (selftest_next >= selftest_modes.size()) console::info("[WW-TEST] self test finished\n");
                }
            }
            // records of the handler, printed here (the console belongs to the main thread)
            const auto head = ring_head.load();
            const unsigned limit = head < ring_size ? head : ring_size;
            while (printed < limit && ring[printed].ready.load(std::memory_order_acquire))
            {
                std::string text;
                format_record(ring[printed], text);
                text += recent_events(8);
                print_console(text);
                ++printed;
            }
            const auto dt = to_ns(qpc() - t0);
            guard_ns += dt;
            if (dt > guard_max_ns) guard_max_ns = dt;
            const auto now = GetTickCount64();
            if (now - last_stats_tick >= 60000)
            {
                last_stats_tick = now;
                FILETIME created{}, exited{}, kernel{}, user{};
                std::uint64_t cpu_ms = 0;
                if (helper_handle && GetThreadTimes(helper_handle, &created, &exited, &kernel, &user))
                    cpu_ms = ((static_cast<std::uint64_t>(kernel.dwHighDateTime) << 32 | kernel.dwLowDateTime) + (static_cast<std::uint64_t>(user.dwHighDateTime) << 32 | user.dwLowDateTime)) / 10000;
                char line[512]{};
                std::snprintf(line, sizeof(line),
                    "[WW] stats secs=%llu frames=%llu guard_us_mean=%.2f guard_us_max=%.1f helper_cpu_ms=%llu threads=%llu scans=%llu sweeps=%llu rearm_passes=%llu lost=%llu refused=%llu suspend_failed=%llu traps=%llu logged=%u dropped=%u handler_us_mean=%.2f handler_us_max=%.1f\n",
                    static_cast<unsigned long long>((now - first_tick) / 1000), static_cast<unsigned long long>(frames), frames ? guard_ns / 1000.0 / static_cast<double>(frames) : 0.0, guard_max_ns / 1000.0,
                    static_cast<unsigned long long>(cpu_ms), static_cast<unsigned long long>(known_threads.load()), static_cast<unsigned long long>(scans.load()), static_cast<unsigned long long>(sweeps.load()),
                    static_cast<unsigned long long>(rearm_total.load()), static_cast<unsigned long long>(lost_total.load()), static_cast<unsigned long long>(refused_total.load()),
                    static_cast<unsigned long long>(suspend_failed.load()), static_cast<unsigned long long>(traps_total.load()), (head < ring_size ? head : ring_size), ring_dropped.load(),
                    traps_total.load() ? handler_ns.load() / 1000.0 / static_cast<double>(traps_total.load()) : 0.0, handler_max_ns.load() / 1000.0);
                std::string text = line;
                for (int i = 0; i < target_count; ++i)
                {
                    char t[240]{};
                    std::snprintf(t, sizeof(t), "[WW] stats target %s addr=0x%llX value=0x%llX traps=%llu logged=%llu\n", targets[i].name, static_cast<unsigned long long>(targets[i].addr.load()),
                        static_cast<unsigned long long>(targets[i].shadow.load()), static_cast<unsigned long long>(targets[i].traps.load()), static_cast<unsigned long long>(targets[i].logged.load()));
                    text += t;
                }
                for (unsigned i = 0; i < writer_slots; ++i)
                    if (writers[i].tid.load())
                    {
                        char label[80]{}, t[160]{};
                        thread_label(writers[i].tid.load(), label, sizeof(label));
                        std::snprintf(t, sizeof(t), "[WW] stats writer thread %s traps=%llu\n", label, static_cast<unsigned long long>(writers[i].count.load()));
                        text += t;
                    }
                write_file(text);
                print_console(text);
            }
        }

        // ---- test commands (lab only) --------------------------------------------------------------------------------------------------------------
        __declspec(noinline) void test_store(volatile std::uint64_t* address, const std::uint64_t value) { *address = value; }
        __declspec(noinline) void test_block(volatile void* address) { static void* (*volatile fill)(void*, int, std::size_t) = std::memset; fill(const_cast<void*>(address), 0, 64); }
        bool within(const std::uint64_t address, const void* begin, const void* end) { return address >= reinterpret_cast<std::uint64_t>(begin) && address < reinterpret_cast<std::uint64_t>(end); }
        // The newest logged record must name the test function: its RIP inside [begin, end) (a store), or a return address of the stack inside it (a block write: the RIP is in memset).
        bool judge(const char* what, const void* begin, const void* end, const unsigned before, const bool block, const bool other_thread)
        {
            const auto head = ring_head.load();
            const unsigned limit = head < ring_size ? head : ring_size;
            if (limit <= before) { console::error("[WW-TEST] FAIL %s: no hit was recorded (traps=%llu)\n", what, static_cast<unsigned long long>(traps_total.load())); return false; }
            const auto& r = ring[limit - 1];
            const bool rip_in = within(r.rip, begin, end);
            bool stack_in = false;
            for (unsigned i = 0; i < r.unwind_count; ++i) stack_in = stack_in || within(r.unwind[i], begin, end);
            for (unsigned i = 0; i < r.scan_count; ++i) stack_in = stack_in || within(r.scan[i], begin, end);
            const bool thread_ok = !other_thread || r.tid != main_tid.load();
            const bool pass = (block ? stack_in : rip_in) && thread_ok;
            char place[96]{};
            locate(r.rip, place, sizeof(place));
            char line[400]{};
            std::snprintf(line, sizeof(line), "[WW-TEST] %s %s: function [0x%llX, 0x%llX) hit rip=%s rip_in_function=%d function_in_stack=%d tid=%u main=%u old=0x%llX new=0x%llX\n",
                pass ? "PASS" : "FAIL", what, reinterpret_cast<unsigned long long>(begin), reinterpret_cast<unsigned long long>(end), place, rip_in, stack_in, r.tid, main_tid.load(),
                static_cast<unsigned long long>(r.old_value), static_cast<unsigned long long>(r.new_value));
            write_file(line);
            console::info("%s", line);
            return pass;
        }
        void run_test(const std::string& mode)
        {
            if (!enabled) { console::error("[WW-TEST] the write watch is not on\n"); return; }
            const bool scratch = mode.rfind("scratch", 0) == 0;
            volatile std::uint64_t* cell = nullptr;
            std::uint64_t expect = hit_vtable;
            for (int i = 0; i < target_count && !cell; ++i)
            {
                const bool is_scratch = targets[i].terms[0].kind == 's';
                if (scratch != is_scratch) continue;
                const auto address = targets[i].addr.load();
                if (!address) continue;
                cell = reinterpret_cast<volatile std::uint64_t*>(address);
                expect = targets[i].expect;
            }
            if (!cell) { console::error("[WW-TEST] no %s target is resolved (start with -paris-write-watch %s)\n", scratch ? "scratch" : "cg", scratch ? "scratch" : "hitresult"); return; }
            if (scratch) for (int i = 0; i < 8; ++i) scratch_cell[i] = expect; // the watched cell holds its expected value before the test
            const auto h0 = ring_head.load();
            const unsigned before = h0 < ring_size ? h0 : ring_size;
            add_event(("test " + mode).c_str(), mode.size() + 5);
            if (mode == "scratch_memset")
            {
                test_block(cell);
                test_store(cell, expect);
                judge("scratch_memset", reinterpret_cast<const void*>(&test_block), reinterpret_cast<const char*>(&test_block) + 0x80, before, true, false);
            }
            else if (mode == "scratch_thread")
            {
                std::thread worker([cell] { Sleep(600); test_store(cell, 0); });
                worker.join();
                test_store(cell, expect);
                judge("scratch_thread", reinterpret_cast<const void*>(&test_store), reinterpret_cast<const char*>(&test_store) + 0x30, before, false, true);
            }
            else // scratch, real: the (real) qword is zero for the time of one instruction, then restored
            {
                test_store(cell, 0);
                test_store(cell, expect);
                judge(mode.c_str(), reinterpret_cast<const void*>(&test_store), reinterpret_cast<const char*>(&test_store) + 0x30, before, false, false);
            }
        }
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (game::environment::is_dedi() || !utils::flags::has_flag("paris-write-watch")) return;
            const bool lab = utils::flags::has_flag("paris-isolated-lab");
            std::wstring value;
            argument(L"-paris-write-watch", value);
            std::string list = value.empty() ? "hitresult" : std::string(value.begin(), value.end());
            std::size_t start = 0;
            while (start <= list.size())
            {
                auto end = list.find(',', start);
                if (end == std::string::npos) end = list.size();
                const auto item = list.substr(start, end - start);
                if (!item.empty() && (!add_preset_or_target(item) || (item.find("scratch") != std::string::npos && !lab)))
                {
                    console::error("[WW] refused: target '%s' (presets hitresult, hitresult4, scratch (lab only); or <expression>[=<expected hex>|=any][:1|2|4|8], up to 4; expression: + and - of numbers, cg, cg<0-7>, game, [<address>])\n", item.c_str());
                    return;
                }
                start = end + 1;
            }
            if (!target_count) return;
            std::wstring flag_value;
            use_hw = !argument(L"-paris-write-watch-no-hw", flag_value);
            use_guard = !argument(L"-paris-write-watch-no-guard", flag_value);
            main_only = argument(L"-paris-write-watch-main-only", flag_value);
            log_all = argument(L"-paris-write-watch-all", flag_value);
            if (lab && argument(L"-paris-write-watch-selftest", flag_value) && !flag_value.empty()) selftest_modes = std::string(flag_value.begin(), flag_value.end());
            sweep_ms = number_argument(L"-paris-write-watch-sweep", 2000);
            if (sweep_ms < 200) sweep_ms = 200;
            LARGE_INTEGER frequency{};
            QueryPerformanceFrequency(&frequency);
            qpc_hz = frequency.QuadPart;
            std::uint32_t pe_offset{}, size{};
            if (read_bytes(game_base + 0x3C, &pe_offset, 4) && read_bytes(game_base + pe_offset + 0x50, &size, 4)) image_size = size;
            if (!image_size) image_size = 0x2000000;
            for (auto& cell : scratch_cell) cell = hit_vtable;
            first_tick = GetTickCount64();
            CreateDirectoryW(L"iw7-mod", nullptr);
            CreateDirectoryW(L"iw7-mod\\paris-write-watch", nullptr);
            wchar_t name[160]{};
            SYSTEMTIME now{};
            GetSystemTime(&now);
            std::swprintf(name, 160, L"iw7-mod\\paris-write-watch\\ww-%04u%02u%02u%02u%02u%02u-%lu.log", now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond, GetCurrentProcessId());
            log_file = CreateFileW(name, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            enabled = true;
            veh = AddVectoredExceptionHandler(1, handler);
            console_hook.create(reinterpret_cast<void*>(&console::dispatch_message), reinterpret_cast<void*>(console_stub));
            scheduler::loop(frame, scheduler::main);
            helper = std::thread(helper_main);
            helper_handle = helper.native_handle();
            char line[400]{};
            std::snprintf(line, sizeof(line), "[WW] ready: %d target(s), hardware=%d guard=%d threads=%s sweep=%u ms, all writes=%d, game image 0x%llX..+0x%llX, log iw7-mod/paris-write-watch\n", target_count, use_hw, use_guard,
                main_only ? "main" : "all", sweep_ms, log_all, static_cast<unsigned long long>(game_base), static_cast<unsigned long long>(image_size));
            write_file(line);
            console::info("%s", line);
            if (lab) command::add("paris_ww_test", [](const command::params& params) { run_test(params.size() > 1 ? params.get(1) : "scratch"); });
        }
        void pre_destroy() override
        {
            if (!enabled) return;
            stop.store(true);
            if (helper.joinable()) helper.join();
            write_file("[WW] stopped\n");
        }
    };
}

REGISTER_COMPONENT(paris_write_watch::component)
