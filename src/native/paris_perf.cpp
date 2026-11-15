#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "scheduler.hpp"
#include "command.hpp"
#include "console/console.hpp"
#include "paris_stack.hpp"
#include <utils/flags.hpp>
#include <utils/hook.hpp>
#include <utils/io.hpp>
#include "game/game.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <tlhelp32.h>
#include <psapi.h>

// Performance recorder for isolated lab clients (-paris-perf with -paris-isolated-lab).
//
//   paris_perf_begin <name>   start a measurement window
//   paris_perf_end            stop it and write iw7-mod/paris-perf/<name>.json
//
// A window holds every frame interval (one timestamp per pass of the renderer pipeline), a sampling profile of the
// game's threads (program counter plus the call stack inside the game image, about 1000 samples a second for the main
// and render threads and a rotating share for the others), the CPU time of every thread, the module list and the
// process memory. Nothing is measured outside a window except the frame clock. Addresses are raw: the engine map
// (ops/engine-map) turns them into functions offline.
//
// Sampler rule: between SuspendThread and ResumeThread it touches no heap, no file and no lock. A suspended thread
// may hold any of them. Function entries of the game image come from its own exception directory, read once.
//
// Snapshot entity count (read only): the client's snapshot parser FUN_1409B7C30(client, message, time, previous, snapshot) is
// wrapped; when it returns, the dword at [snapshot+0x626C] is the number of entity records of that snapshot (set to 0 at the entry,
// +1 per record). A window keeps the calls, the maximum and the mean. The wrapper is left out, with an error line, when the
// first bytes of the function are not the expected ones.
//
// Agent motion (read only, a37): how smoothly the agents are drawn, per group. FUN_1407BFF40(localClient, centity) runs once per entity
// and frame at the end of CG_ProcessEntity (FUN_1407AA9E0), after the position update FUN_1407AE190 has written the render position
// (centity+0x1C, three floats). Its first instruction is wrapped by an assembly pre-hook that reads (nothing is written) and jumps on
// with the arguments and the return address untouched. centity+0x700 is the entity number (checked: centity - number x 0x870 must be
// one base for every sample, else the sample is counted in base_mismatch and dropped), centity+0x704 the entity type. Agents are the
// character slots 18..characters-1; the groups are "low" (18..41, the numbers FUN_1407AE190 interpolates between the two snapshots at
// 0x1407AE222) and "high" (42.., which take the generic path: the trajectory evaluated at the render time). Per entity the last four
// positions and call times are kept; a sample is: jerk = |p(t) - 2 p(t-1) + p(t-2)| / frame time in ms (units per ms; only when the
// entity moved more than 0.5 over those two steps), and stutter = the position did not change (under 0.0001) in a frame that follows a
// movement of more than 0.5 between t-3 and t-1. A gap of over 100 ms or a jump of over 300 units restarts the entity's history (a
// spawn). Output: "agent_motion" in the window file.
//
// The snapshot interpolation limit of FUN_1407AE190 (the compare at 0x1407AE222) is not changed here: with -agent-capacity the capacity component
// installs a cave there (agents below the character count take the interpolation; docs/AGENT-CAPACITY-ENGINE.md). This meter reads the result.
namespace paris_perf
{
    namespace
    {
        // The stack capture (image reading, unwind, raw_sample) is shared with the hang reporter: paris_stack.hpp.
        using paris_stack::capture;
        using paris_stack::function_count;
        using paris_stack::image_base;
        using paris_stack::raw_sample;
        using paris_stack::read_image;
        using paris_stack::text_begin;
        using paris_stack::text_end;
        using paris_stack::unwind_ready;

        constexpr std::size_t max_frames = 1u << 20;
        constexpr std::size_t max_threads = 200;
        constexpr std::size_t others_per_tick = 3;
        constexpr std::size_t max_stacks = 200000;

        struct thread_info
        {
            DWORD id{};
            HANDLE handle{};
            int role{}; // 0 main, 1 render, 2 other
            ULONGLONG user0{}, kernel0{}, user1{}, kernel1{};
            std::uint64_t samples{};
            std::uint64_t failures{};
        };

        std::atomic<DWORD> main_thread{0}, render_thread{0};
        std::vector<std::int64_t> frame_qpc;       // renderer thread writes while a window is open
        std::atomic<bool> window_open{false};
        std::atomic<bool> sampler_stop{false};
        std::thread sampler;
        std::mutex window_mutex;                   // begin/end only
        std::string window_name;
        std::int64_t qpc_hz{}, begin_qpc{}, end_qpc{};
        std::vector<thread_info> threads;
        std::map<std::string, std::uint32_t> stacks; // key: thread index byte, depth byte, scan byte, then the addresses
        std::uint64_t ticks{}, dropped{};

        constexpr std::uintptr_t snapshot_parse_function = 0x1409B7C30;
        utils::hook::detour snapshot_parse_hook;
        std::atomic<std::uint64_t> snapshot_calls{}, snapshot_sum{}, snapshot_max{};
        int snapshot_parse_stub(const std::uintptr_t client, void* message, const int time, const std::uintptr_t previous, const std::uintptr_t snapshot)
        {
            const int result = snapshot_parse_hook.invoke<int>(client, message, time, previous, snapshot);
            if (window_open.load(std::memory_order_acquire) && snapshot)
            {
                const int count = *reinterpret_cast<const int*>(snapshot + 0x626C);
                if (count >= 0)
                {
                    ++snapshot_calls;
                    snapshot_sum += static_cast<std::uint64_t>(count);
                    auto seen = snapshot_max.load(std::memory_order_relaxed);
                    while (static_cast<std::uint64_t>(count) > seen && !snapshot_max.compare_exchange_weak(seen, static_cast<std::uint64_t>(count))) {}
                }
            }
            return result;
        }

        std::int64_t now()
        {
            LARGE_INTEGER value{};
            QueryPerformanceCounter(&value);
            return value.QuadPart;
        }

        // ---- agent motion ----
        constexpr std::uintptr_t entity_type_function = 0x1407BFF40;   // (localClient, centity), called per entity at the end of CG_ProcessEntity
        constexpr std::uintptr_t entity_stride = 0x870;
        constexpr std::uint32_t first_agent = 18, max_slots = 512;
        constexpr std::size_t max_jerk_samples = 3000000;
        constexpr double restart_gap_ms = 100.0, restart_jump = 300.0, moved_min = 0.5, same_max = 0.0001;

        struct motion_group
        {
            std::vector<float> jerk;
            std::uint64_t frames{}, eligible{}, stutter{};
            double sum{};
            std::array<bool, max_slots> seen{};
            std::map<int, std::uint64_t> types;
        };
        struct motion_entity
        {
            double t[4]{};
            float p[4][3]{};
            int n{};
        };
        std::mutex motion_mutex;
        motion_group motion_low, motion_high;
        std::array<motion_entity, max_slots> motion_state;
        std::uintptr_t motion_base{};
        std::uint64_t motion_mismatch{};
        std::uint32_t motion_characters = 42;
        bool motion_hooked = false;
        utils::hook::detour motion_hook;
        void* motion_original = nullptr;

        std::uint32_t character_count()
        {
            const auto* capacity = game::Dvar_FindVar("agent_capacity");
            const int agents = (capacity && capacity->type == game::DVAR_TYPE_INT && capacity->current.integer >= 24 && capacity->current.integer <= 1000) ? capacity->current.integer : 24;
            return static_cast<std::uint32_t>(agents) + first_agent;
        }
        float distance(const float* a, const float* b)
        {
            const float x = a[0] - b[0], y = a[1] - b[1], z = a[2] - b[2];
            return std::sqrt(x * x + y * y + z * z);
        }
        void motion_reset()
        {
            motion_low = motion_group{};
            motion_high = motion_group{};
            motion_state.fill(motion_entity{});
            motion_base = 0;
            motion_mismatch = 0;
        }
        // Called on the thread that runs CG_ProcessEntity, with the arguments of FUN_1407BFF40.
        void motion_record(const int local_client, const std::uintptr_t cent)
        {
            if (!window_open.load(std::memory_order_acquire) || local_client != 0 || !cent) return;
            const int number = *reinterpret_cast<const int*>(cent + 0x700);
            if (number < static_cast<int>(first_agent) || number >= static_cast<int>(motion_characters) || number >= static_cast<int>(max_slots)) return;
            const int type = *reinterpret_cast<const int*>(cent + 0x704);
            const float* origin = reinterpret_cast<const float*>(cent + 0x1C);
            const double t_ms = static_cast<double>(now()) * 1000.0 / static_cast<double>(qpc_hz);
            std::lock_guard<std::mutex> lock(motion_mutex);
            const std::uintptr_t base = cent - static_cast<std::uintptr_t>(number) * entity_stride;
            if (!motion_base) motion_base = base;
            else if (base != motion_base) { ++motion_mismatch; return; }
            for (int i = 0; i < 3; ++i) if (!std::isfinite(origin[i])) return;
            auto& e = motion_state[static_cast<std::size_t>(number)];
            if (e.n > 0 && t_ms - e.t[e.n - 1] < 0.5) { std::memcpy(e.p[e.n - 1], origin, sizeof(float) * 3); return; }   // same frame (a second caller)
            if (e.n > 0 && (t_ms - e.t[e.n - 1] > restart_gap_ms || distance(origin, e.p[e.n - 1]) > restart_jump)) e.n = 0;
            if (e.n == 4)
            {
                for (int i = 0; i < 3; ++i) { e.t[i] = e.t[i + 1]; std::memcpy(e.p[i], e.p[i + 1], sizeof(float) * 3); }
                e.n = 3;
            }
            e.t[e.n] = t_ms;
            std::memcpy(e.p[e.n], origin, sizeof(float) * 3);
            ++e.n;
            auto& g = number < 42 ? motion_low : motion_high;
            g.seen[static_cast<std::size_t>(number)] = true;
            ++g.frames;
            ++g.types[type];
            if (e.n >= 3)
            {
                const float* p2 = e.p[e.n - 1], * p1 = e.p[e.n - 2], * p0 = e.p[e.n - 3];
                if (distance(p2, p0) > moved_min)
                {
                    const float s0 = p2[0] - 2.0f * p1[0] + p0[0], s1 = p2[1] - 2.0f * p1[1] + p0[1], s2 = p2[2] - 2.0f * p1[2] + p0[2];
                    const double dt = e.t[e.n - 1] - e.t[e.n - 2];
                    const float jerk = static_cast<float>(std::sqrt(static_cast<double>(s0 * s0 + s1 * s1 + s2 * s2)) / (dt > 0.01 ? dt : 0.01));
                    g.sum += jerk;
                    if (g.jerk.size() < max_jerk_samples) g.jerk.push_back(jerk);
                }
            }
            if (e.n == 4 && distance(e.p[2], e.p[0]) > moved_min)
            {
                ++g.eligible;
                if (distance(e.p[3], e.p[2]) < same_max) ++g.stutter;
            }
        }
        void append_group(std::string& out, motion_group& g)
        {
            std::sort(g.jerk.begin(), g.jerk.end());
            const auto pick = [&](const double q) { return g.jerk.empty() ? 0.0 : static_cast<double>(g.jerk[std::min(g.jerk.size() - 1, static_cast<std::size_t>(q * static_cast<double>(g.jerk.size())))]); };
            std::size_t entities = 0;
            for (const bool s : g.seen) entities += s ? 1 : 0;
            char line[512]{};
            _snprintf_s(line, sizeof(line), _TRUNCATE, "{\"entities\":%zu,\"frames\":%llu,\"count\":%zu,\"mean\":%.6f,\"p95\":%.6f,\"p99\":%.6f,\"stutter_eligible\":%llu,\"stutter\":%llu,\"stutter_ratio\":%.6f,\"types\":{",
                entities, static_cast<unsigned long long>(g.frames), g.jerk.size(), g.jerk.empty() ? 0.0 : g.sum / static_cast<double>(g.jerk.size()), pick(0.95), pick(0.99),
                static_cast<unsigned long long>(g.eligible), static_cast<unsigned long long>(g.stutter), g.eligible ? static_cast<double>(g.stutter) / static_cast<double>(g.eligible) : 0.0);
            out += line;
            bool first = true;
            for (const auto& [type, count] : g.types)
            {
                _snprintf_s(line, sizeof(line), _TRUNCATE, "%s\"%d\":%llu", first ? "" : ",", type, static_cast<unsigned long long>(count));
                out += line;
                first = false;
            }
            out += "}}";
        }
        void append_motion(std::string& out)
        {
            std::lock_guard<std::mutex> lock(motion_mutex);
            char line[512]{};
            _snprintf_s(line, sizeof(line), _TRUNCATE, "\"agent_motion\":{\"hooked\":%s,\"characters\":%u,\"base_mismatch\":%llu,\"low\":",
                motion_hooked ? "true" : "false", motion_characters, static_cast<unsigned long long>(motion_mismatch));
            out += line;
            append_group(out, motion_low);
            out += ",\"high\":";
            append_group(out, motion_high);
            out += "},\n";
        }
        void install_motion_hook()
        {
            static const unsigned char code[] = {0x48, 0x89, 0x5C, 0x24, 0x08, 0x57, 0x48, 0x83, 0xEC, 0x20, 0x83, 0xBA, 0x94, 0x07, 0x00, 0x00, 0x00};
            if (std::memcmp(reinterpret_cast<const void*>(entity_type_function), code, sizeof(code)) != 0)
            {
                console::error("[Paris perf] entity function at 0x%llX: code differs from the expected bytes, the agent motion meter is left out\n", static_cast<unsigned long long>(entity_type_function));
                return;
            }
            // Pre-hook: save the argument registers, call motion_record(rcx, rdx), restore them and jump to the original with the return address untouched.
            const auto stub = utils::hook::assemble([](utils::hook::assembler& a)
            {
                using namespace asmjit::x86;
                a.push(rcx); a.push(rdx); a.push(r8); a.push(r9); a.push(r10); a.push(r11);
                a.sub(rsp, 0x28);
                a.mov(rax, reinterpret_cast<std::uint64_t>(&motion_record));
                a.call(rax);
                a.add(rsp, 0x28);
                a.pop(r11); a.pop(r10); a.pop(r9); a.pop(r8); a.pop(rdx); a.pop(rcx);
                a.mov(rax, reinterpret_cast<std::uint64_t>(&motion_original));
                a.mov(rax, qword_ptr(rax));
                a.jmp(rax);
            });
            motion_hook.create(entity_type_function, stub);
            motion_original = motion_hook.get_original();
            motion_hooked = true;
        }
        void account(const std::size_t index, const raw_sample& sample)
        {
            std::string key;
            key.reserve(3 + (sample.depth + sample.scanned) * 8);
            key.push_back(static_cast<char>(index));
            key.push_back(static_cast<char>(sample.depth));
            key.push_back(static_cast<char>(sample.scanned));
            key.append(reinterpret_cast<const char*>(sample.pc), sample.depth * sizeof(std::uint64_t));
            key.append(reinterpret_cast<const char*>(sample.scan), sample.scanned * sizeof(std::uint64_t));
            const auto found = stacks.find(key);
            if (found != stacks.end()) ++found->second;
            else if (stacks.size() < max_stacks) stacks.emplace(std::move(key), 1u);
            else ++dropped;
        }
        void sample_thread(const std::size_t index)
        {
            auto& thread = threads[index];
            raw_sample sample{};
            if (SuspendThread(thread.handle) == static_cast<DWORD>(-1)) { ++thread.failures; return; }
            const bool ok = capture(thread.handle, sample);
            ResumeThread(thread.handle);
            if (!ok) { ++thread.failures; return; }
            ++thread.samples;
            account(index, sample);
        }
        void sampler_loop()
        {
            // A high-resolution waitable timer: about one tick a millisecond without touching the system timer period.
            const HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, 0x00000002, TIMER_ALL_ACCESS);
            std::size_t next_other = 0;
            std::vector<std::size_t> hot, others;
            for (std::size_t i = 0; i < threads.size(); ++i) (threads[i].role == 2 ? others : hot).push_back(i);
            while (!sampler_stop.load())
            {
                ++ticks;
                for (const auto index : hot) sample_thread(index);
                for (std::size_t n = 0; n < others_per_tick && !others.empty(); ++n)
                {
                    sample_thread(others[next_other]);
                    next_other = (next_other + 1) % others.size();
                }
                LARGE_INTEGER due{};
                due.QuadPart = -10000; // 1 ms in 100 ns units
                if (timer && SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE)) WaitForSingleObject(timer, 20);
                else Sleep(1);
            }
            if (timer) CloseHandle(timer);
        }
        void thread_times(thread_info& thread, const bool first)
        {
            FILETIME created{}, exited{}, kernel{}, user{};
            if (!GetThreadTimes(thread.handle, &created, &exited, &kernel, &user)) return;
            const auto k = (static_cast<ULONGLONG>(kernel.dwHighDateTime) << 32) | kernel.dwLowDateTime;
            const auto u = (static_cast<ULONGLONG>(user.dwHighDateTime) << 32) | user.dwLowDateTime;
            if (first) { thread.kernel0 = k; thread.user0 = u; }
            else { thread.kernel1 = k; thread.user1 = u; }
        }
        bool valid_name(const std::string& name)
        {
            return !name.empty() && name.size() <= 32 && name.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789_") == std::string::npos;
        }
        void begin(const std::string& name)
        {
            std::lock_guard<std::mutex> lock(window_mutex);
            if (window_open.load()) { console::error("[Paris perf] a window is already open: %s\n", window_name.c_str()); return; }
            if (!valid_name(name)) { console::error("[Paris perf] a window name is 1 to 32 characters of a-z, 0-9 and _\n"); return; }
            const auto main_id = main_thread.load(), render_id = render_thread.load();
            if (!main_id || !render_id) { console::error("[Paris perf] the main or the render thread is not known yet\n"); return; }
            threads.clear();
            stacks.clear();
            ticks = dropped = 0;
            snapshot_calls = 0; snapshot_sum = 0; snapshot_max = 0;
            {
                std::lock_guard<std::mutex> motion_lock(motion_mutex);
                motion_reset();
                motion_characters = character_count();
            }
            const auto self = GetCurrentProcessId();
            const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
            if (snapshot != INVALID_HANDLE_VALUE)
            {
                THREADENTRY32 entry{};
                entry.dwSize = sizeof(entry);
                if (Thread32First(snapshot, &entry))
                {
                    do
                    {
                        if (entry.th32OwnerProcessID != self || threads.size() >= max_threads) continue;
                        thread_info info{};
                        info.id = entry.th32ThreadID;
                        info.role = info.id == main_id ? 0 : info.id == render_id ? 1 : 2;
                        info.handle = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, info.id);
                        if (!info.handle) continue;
                        thread_times(info, true);
                        threads.push_back(info);
                    } while (Thread32Next(snapshot, &entry));
                }
                CloseHandle(snapshot);
            }
            window_name = name;
            frame_qpc.clear();
            frame_qpc.reserve(1u << 16);
            sampler_stop = false;
            begin_qpc = now();
            window_open = true;
            sampler = std::thread([]
            {
                // The sampler never samples itself: it was created after the snapshot.
                sampler_loop();
            });
            console::info("[Paris perf] begin name=%s threads=%zu unwind=%d\n", name.c_str(), threads.size(), static_cast<int>(unwind_ready));
        }
        void hex(std::string& out, const std::uint64_t value)
        {
            char text[20]{};
            _snprintf_s(text, sizeof(text), _TRUNCATE, "%llX", static_cast<unsigned long long>(value));
            out += text;
        }
        void end()
        {
            std::lock_guard<std::mutex> lock(window_mutex);
            if (!window_open.load()) { console::error("[Paris perf] no window is open\n"); return; }
            window_open = false;
            end_qpc = now();
            sampler_stop = true;
            if (sampler.joinable()) sampler.join();
            for (auto& thread : threads) thread_times(thread, false);

            std::string out;
            out.reserve(1u << 20);
            const double seconds = static_cast<double>(end_qpc - begin_qpc) / static_cast<double>(qpc_hz);
            char line[512]{};
            _snprintf_s(line, sizeof(line), _TRUNCATE,
                "{\"schema\":\"iw7.perf-window/1\",\"name\":\"%s\",\"pid\":%lu,\"seconds\":%.6f,\"qpc_hz\":%lld,"
                "\"image\":{\"base\":\"%llX\",\"text_begin\":\"%llX\",\"text_end\":\"%llX\",\"unwind\":%s,\"functions\":%zu},\n",
                window_name.c_str(), GetCurrentProcessId(), seconds, static_cast<long long>(qpc_hz),
                static_cast<unsigned long long>(image_base), static_cast<unsigned long long>(text_begin), static_cast<unsigned long long>(text_end),
                unwind_ready ? "true" : "false", function_count);
            out += line;
            out += "\"frames_us\":[";
            for (std::size_t i = 1; i < frame_qpc.size(); ++i)
            {
                const auto us = (frame_qpc[i] - frame_qpc[i - 1]) * 1000000 / qpc_hz;
                if (i > 1) out += ',';
                out += std::to_string(us);
            }
            {
                const auto n = snapshot_calls.load();
                _snprintf_s(line, sizeof(line), _TRUNCATE, "],\n\"snapshot_entities\":{\"calls\":%llu,\"max\":%llu,\"mean\":%.3f},\n",
                    static_cast<unsigned long long>(n), static_cast<unsigned long long>(snapshot_max.load()),
                    n ? static_cast<double>(snapshot_sum.load()) / static_cast<double>(n) : 0.0);
                out += line;
                append_motion(out);
                out += "\"threads\":[";
            }
            std::uint64_t samples = 0;
            for (std::size_t i = 0; i < threads.size(); ++i)
            {
                const auto& thread = threads[i];
                samples += thread.samples;
                _snprintf_s(line, sizeof(line), _TRUNCATE, "%s{\"id\":%lu,\"role\":\"%s\",\"user_ms\":%.3f,\"kernel_ms\":%.3f,\"samples\":%llu,\"failures\":%llu}",
                    i ? "," : "", thread.id, thread.role == 0 ? "main" : thread.role == 1 ? "render" : "other",
                    static_cast<double>(thread.user1 - thread.user0) / 10000.0, static_cast<double>(thread.kernel1 - thread.kernel0) / 10000.0,
                    static_cast<unsigned long long>(thread.samples), static_cast<unsigned long long>(thread.failures));
                out += line;
            }
            _snprintf_s(line, sizeof(line), _TRUNCATE, "],\n\"sampler\":{\"ticks\":%llu,\"hz\":%.1f,\"samples\":%llu,\"dropped\":%llu,\"others_per_tick\":%zu},\n\"stacks\":[",
                static_cast<unsigned long long>(ticks), seconds > 0 ? static_cast<double>(ticks) / seconds : 0.0,
                static_cast<unsigned long long>(samples), static_cast<unsigned long long>(dropped), others_per_tick);
            out += line;
            bool first = true;
            for (const auto& [key, count] : stacks)
            {
                const auto index = static_cast<unsigned char>(key[0]);
                const std::size_t depth = static_cast<unsigned char>(key[1]), scanned = static_cast<unsigned char>(key[2]);
                const auto* values = reinterpret_cast<const std::uint64_t*>(key.data() + 3);
                out += first ? "\n[" : ",\n[";
                first = false;
                out += std::to_string(index);
                out += ',';
                out += std::to_string(count);
                out += ",\"";
                for (std::size_t i = 0; i < depth; ++i) { if (i) out += ';'; hex(out, values[i]); }
                out += "\",\"";
                for (std::size_t i = 0; i < scanned; ++i) { if (i) out += ';'; hex(out, values[depth + i]); }
                out += "\"]";
            }
            out += "],\n\"modules\":[";
            HMODULE modules[512]{};
            DWORD needed{};
            if (EnumProcessModules(GetCurrentProcess(), modules, sizeof(modules), &needed))
            {
                const std::size_t count = needed / sizeof(HMODULE) < 512 ? needed / sizeof(HMODULE) : 512;
                for (std::size_t i = 0; i < count; ++i)
                {
                    MODULEINFO info{};
                    char name[MAX_PATH]{};
                    if (!GetModuleInformation(GetCurrentProcess(), modules[i], &info, sizeof(info))) continue;
                    if (!GetModuleBaseNameA(GetCurrentProcess(), modules[i], name, sizeof(name))) continue;
                    for (auto& c : name) if (c == '"' || c == '\\') c = '_';
                    _snprintf_s(line, sizeof(line), _TRUNCATE, "%s{\"base\":\"%llX\",\"size\":%lu,\"name\":\"%s\"}", i ? "," : "",
                        static_cast<unsigned long long>(reinterpret_cast<std::uintptr_t>(info.lpBaseOfDll)), info.SizeOfImage, name);
                    out += line;
                }
            }
            PROCESS_MEMORY_COUNTERS_EX memory{};
            memory.cb = sizeof(memory);
            GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&memory), sizeof(memory));
            _snprintf_s(line, sizeof(line), _TRUNCATE, "],\n\"memory\":{\"working_set\":%llu,\"private\":%llu}}\n",
                static_cast<unsigned long long>(memory.WorkingSetSize), static_cast<unsigned long long>(memory.PrivateUsage));
            out += line;
            for (auto& thread : threads) if (thread.handle) CloseHandle(thread.handle);
            const std::string path = "iw7-mod/paris-perf/" + window_name + ".json";
            const bool written = utils::io::write_file(path, out);
            console::info("[Paris perf] end name=%s seconds=%.3f frames=%zu samples=%llu stacks=%zu written=%d\n", window_name.c_str(), seconds,
                frame_qpc.size(), static_cast<unsigned long long>(samples), stacks.size(), static_cast<int>(written));
            threads.clear();
            stacks.clear();
        }
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (!utils::flags::has_flag("paris-perf") || !utils::flags::has_flag("paris-isolated-lab")) return;
            LARGE_INTEGER frequency{};
            QueryPerformanceFrequency(&frequency);
            qpc_hz = frequency.QuadPart;
            read_image();
            static const unsigned char parse_code[] = {0x40, 0x53, 0x55, 0x56, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57, 0x48, 0x81, 0xEC, 0x78, 0x01, 0x00};
            if (std::memcmp(reinterpret_cast<const void*>(snapshot_parse_function), parse_code, sizeof(parse_code)) == 0)
                snapshot_parse_hook.create(snapshot_parse_function, snapshot_parse_stub);
            else console::error("[Paris perf] snapshot parser at 0x%llX: code differs from the expected bytes, its counter is left out\n",
                static_cast<unsigned long long>(snapshot_parse_function));
            install_motion_hook();
            scheduler::loop([]
            {
                if (!render_thread.load()) render_thread = GetCurrentThreadId();
                if (window_open.load() && frame_qpc.size() < max_frames) frame_qpc.push_back(now());
            }, scheduler::renderer);
            scheduler::loop([]
            {
                if (!main_thread.load()) main_thread = GetCurrentThreadId();
            }, scheduler::main);
            command::add("paris_perf_begin", [](const command::params& params)
            {
                begin(params.size() > 1 ? params.get(1) : "");
            });
            command::add("paris_perf_end", [] { end(); });
            console::info("[Paris perf] ready unwind=%d functions=%zu\n", static_cast<int>(unwind_ready), function_count);
        }
        void pre_destroy() override
        {
            if (window_open.load())
            {
                sampler_stop = true;
                if (sampler.joinable()) sampler.join();
            }
        }
    };
}

REGISTER_COMPONENT(paris_perf::component)
