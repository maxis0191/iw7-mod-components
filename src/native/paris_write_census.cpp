#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "console/console.hpp"
#include <utils/flags.hpp>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <thread>

// Write census for lab clients (-paris-write-census [<regions>]; compiled with -Perf, lab only: needs -paris-isolated-lab): which instruction writes where in a whole object.
//
// Why: the write watch (paris_write_watch.cpp) names the writer of up to four cells. The a73 finding (a 0xC0 byte table of the client object `cg` sized for 42 characters and indexed up
// to 263) was a table nobody had listed; the census answers the question for the whole object: every store into it, by instruction. Run the same scripted scene at -agent-capacity 24 and at
// -agent-capacity 264 and diff the two files (ops/engine/census_diff.py): a writer that appears only at 264, or whose offsets reach further, is a table indexed by a character number.
//
// How: every page of a region is made PAGE_READONLY (the original protection is kept). A store faults (EXCEPTION_ACCESS_VIOLATION, write) in a vectored handler (first in the chain):
// it counts the store per site (the RIP and the region), keeps the written offset (minimum, maximum, the first 128 distinct ones), makes the page writable, sets the trap flag and
// continues; the single step that follows puts the protection back. Reads never fault. The handler allocates nothing and takes no lock. A page that faults more than
// -paris-write-census-limit times (default 20000: a hot page; the first 20000 stores of a page are seen, so a table's rows still show) is released and armed again 3 s later with a new budget (the dump lists the pages released at that moment): a writer that starts after the budget is seen in a later window. Slow on purpose (a frame costs the number of
// stores into the object times about 20 us): a census run, never a play session.
// Regions: `cg` (the Zombies client object of local client 0, found like the write watch does: the plain array base 0x141FDBEF0, a vtable of the game image in its first qword; re-armed when it
// moves; the size from -agent-capacity: 0xFDEA8 stock, else the grown object plus the table of the capacity component) and `abs:<hex address>:<decimal size>` (a static block).
// Output: iw7-mod/paris-write-census/census-<time>-<pid>.tsv, rewritten every 5 s by a helper thread (so it survives a killed client).
namespace paris_write_census
{
    namespace
    {
        constexpr std::uint64_t cg_cp_array = 0x141FDBEF0, game_base = 0x140000000;
        constexpr unsigned max_regions = 16, max_pages = 3072, site_count = 8192, sample_count = 128;
        constexpr std::uint64_t page_size = 0x1000;

        struct page { std::atomic<int> state{0}; std::atomic<std::uint32_t> faults{0}; std::uint32_t original{}; };   // state 0 free, 1 protected, 2 released (hot)
        struct region
        {
            char name[40]{};
            bool is_cg{};
            std::uint64_t fixed_base{}, size{};
            std::atomic<std::uint64_t> base{0};     // 0 while not armed
            std::uint64_t first_page{}, page_total{};
            page pages[max_pages];
        };
        struct site
        {
            std::atomic<std::uint64_t> key{0};      // rip + (region + 1) << 48
            std::atomic<std::uint64_t> count{0}, main_count{0};
            std::atomic<std::uint32_t> min_offset{0xFFFFFFFFu}, max_offset{0}, distinct{0};
            std::atomic<std::uint32_t> sample[sample_count];
        };

        region regions[max_regions];
        unsigned region_count{};
        site sites[site_count];
        std::atomic<unsigned> sites_used{0}, sites_lost{0};
        std::atomic<std::uint64_t> faults_total{0}, outside_total{0}, released_total{0};
        std::atomic<unsigned> main_tid{0};
        unsigned fault_limit{20000}, cg_agents{0}, delay_seconds{0};
        std::uint64_t started_tick{};
        bool enabled{};
        PVOID veh{};
        std::thread helper;
        std::atomic<bool> stop{false};
        HANDLE out_file{INVALID_HANDLE_VALUE};
        thread_local struct { std::uint64_t base[2]; unsigned count; region* owner; unsigned index[2]; } pending;

        bool read_bytes(const std::uint64_t address, void* out, const std::size_t len) noexcept
        {
            __try { std::memcpy(out, reinterpret_cast<const void*>(address), len); return true; }
            __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
        }
        std::uint64_t image_end() noexcept { return game_base + 0x3000000; }
        std::uint64_t cg_object() noexcept
        {
            std::uint64_t base{}, vtable{};
            if (!read_bytes(cg_cp_array, &base, 8) || base < 0x10000 || base > 0x7FFFFFFEFFFFull) return 0;
            if (!read_bytes(base, &vtable, 8) || vtable < game_base || vtable >= image_end()) return 0;
            return base;
        }
        // The client object of this build: stock 0xFDEA8; with -agent-capacity n: the 42 character records grow by (C - 42) x 0x2CA0, then C flag bytes, then (with the a76 table) C rows of 0xC0 bytes.
        std::uint64_t cg_size() noexcept
        {
            if (!cg_agents) return 0xFDEA8;
            const std::uint64_t c = 18 + cg_agents, flags = 0xFDEA8 + (c - 42) * 0x2CA0, table = (flags + c + 15) & ~15ull;
            return (table + c * 0xC0 + 15) & ~15ull;
        }

        site* find_site(const std::uint64_t key) noexcept
        {
            for (unsigned probe = 0, i = static_cast<unsigned>((key * 0x9E3779B97F4A7C15ull) >> 51) % site_count; probe < site_count; ++probe, i = (i + 1) % site_count)
            {
                auto& s = sites[i];
                auto seen = s.key.load(std::memory_order_acquire);
                if (seen == key) return &s;
                if (seen == 0)
                {
                    std::uint64_t zero = 0;
                    if (s.key.compare_exchange_strong(zero, key)) { sites_used.fetch_add(1); return &s; }
                    if (zero == key) return &s;
                }
            }
            sites_lost.fetch_add(1);
            return nullptr;
        }
        void note(region& r, const unsigned region_index, const std::uint64_t rip, const std::uint64_t offset) noexcept
        {
            auto* s = find_site(rip + (static_cast<std::uint64_t>(region_index) + 1) * 0x1000000000000ull);
            if (!s) return;
            s->count.fetch_add(1);
            if (GetCurrentThreadId() == main_tid.load()) s->main_count.fetch_add(1);
            const auto off = static_cast<std::uint32_t>(offset);
            for (auto m = s->min_offset.load(); off < m && !s->min_offset.compare_exchange_weak(m, off);) {}
            for (auto m = s->max_offset.load(); off > m && !s->max_offset.compare_exchange_weak(m, off);) {}
            const auto n = s->distinct.load();
            if (n >= sample_count) return;
            for (unsigned i = 0; i < n; ++i) if (s->sample[i].load(std::memory_order_relaxed) == off) return;
            const auto slot = s->distinct.fetch_add(1);
            if (slot < sample_count) s->sample[slot].store(off, std::memory_order_relaxed);
            else s->distinct.store(sample_count);
            (void)r;
        }

        LONG CALLBACK handler(EXCEPTION_POINTERS* ep) noexcept
        {
            const auto code = ep->ExceptionRecord->ExceptionCode;
            if (code == EXCEPTION_SINGLE_STEP)
            {
                if (!pending.count) return EXCEPTION_CONTINUE_SEARCH;
                for (unsigned i = 0; i < pending.count; ++i)
                {
                    auto& p = pending.owner->pages[pending.index[i]];
                    if (p.state.load() == 1) { DWORD old{}; VirtualProtect(reinterpret_cast<void*>(pending.base[i]), page_size, PAGE_READONLY, &old); }
                }
                pending.count = 0;
                return EXCEPTION_CONTINUE_EXECUTION;
            }
            if (code != EXCEPTION_ACCESS_VIOLATION || ep->ExceptionRecord->NumberParameters < 2 || ep->ExceptionRecord->ExceptionInformation[0] != 1) return EXCEPTION_CONTINUE_SEARCH;
            const auto address = static_cast<std::uint64_t>(ep->ExceptionRecord->ExceptionInformation[1]);
            for (unsigned ri = 0; ri < region_count; ++ri)
            {
                auto& r = regions[ri];
                const auto base = r.base.load();
                if (!r.page_total) continue;
                const auto page_index = (address >> 12) - r.first_page;
                if (address < (r.first_page << 12) || page_index >= r.page_total) continue;
                auto& p = r.pages[page_index];
                // a page that is not (or no longer) ours: the store faulted just before the page was released or armed by the helper; the page is writable now, run the store again
                if (p.state.load() != 1) return EXCEPTION_CONTINUE_EXECUTION;
                faults_total.fetch_add(1);
                if (base && address >= base && address < base + r.size) note(r, ri, reinterpret_cast<std::uint64_t>(ep->ExceptionRecord->ExceptionAddress), address - base);
                else outside_total.fetch_add(1);
                DWORD old{};
                if (p.faults.fetch_add(1) + 1 > fault_limit)
                {
                    p.state.store(2);
                    released_total.fetch_add(1);
                    VirtualProtect(reinterpret_cast<void*>(address & ~(page_size - 1)), page_size, p.original, &old);
                    return EXCEPTION_CONTINUE_EXECUTION;
                }
                pending.owner = &r;
                pending.count = 1;
                pending.base[0] = address & ~(page_size - 1);
                pending.index[0] = static_cast<unsigned>(page_index);
                VirtualProtect(reinterpret_cast<void*>(pending.base[0]), page_size, p.original, &old);
                // a store that crosses into the next page (16 bytes at the end of this one)
                if ((address & (page_size - 1)) > page_size - 32 && page_index + 1 < r.page_total && r.pages[page_index + 1].state.load() == 1)
                {
                    pending.base[1] = pending.base[0] + page_size;
                    pending.index[1] = static_cast<unsigned>(page_index + 1);
                    pending.count = 2;
                    VirtualProtect(reinterpret_cast<void*>(pending.base[1]), page_size, r.pages[page_index + 1].original, &old);
                }
                ep->ContextRecord->EFlags |= 0x100;
                return EXCEPTION_CONTINUE_EXECUTION;
            }
            return EXCEPTION_CONTINUE_SEARCH;
        }

        void protect(region& r, const std::uint64_t base)
        {
            r.first_page = base >> 12;
            r.page_total = ((base + r.size + page_size - 1) >> 12) - r.first_page;
            if (r.page_total > max_pages) r.page_total = max_pages;
            r.base.store(base);   // before the first page is protected: a store that faults must find its region
            unsigned armed = 0, skipped = 0;
            DWORD first_skip_state = 0, first_skip_protect = 0, first_skip_type = 0;
            for (std::uint64_t i = 0; i < r.page_total; ++i)
            {
                const auto address = (r.first_page + i) << 12;
                MEMORY_BASIC_INFORMATION m{};
                auto& p = r.pages[i];
                p.faults.store(0);
                if (!VirtualQuery(reinterpret_cast<void*>(address), &m, sizeof(m)) || m.State != MEM_COMMIT || ((m.Protect & 0xFF) != PAGE_READWRITE && (m.Protect & 0xFF) != PAGE_WRITECOPY && (m.Protect & 0xFF) != PAGE_EXECUTE_READWRITE && (m.Protect & 0xFF) != PAGE_EXECUTE_WRITECOPY)) { if (!skipped) { first_skip_state = m.State; first_skip_protect = m.Protect; first_skip_type = m.Type; } p.state.store(0); ++skipped; continue; }   // the data sections of the image are copy-on-write until first written
                p.original = m.Protect;
                p.state.store(1);
                DWORD old{};
                if (VirtualProtect(reinterpret_cast<void*>(address), page_size, PAGE_READONLY, &old)) ++armed; else { p.state.store(0); ++skipped; }
            }
            console::info("[WC] armed %s base=0x%llX size=0x%llX pages=%u skipped=%u\n", r.name, static_cast<unsigned long long>(base), static_cast<unsigned long long>(r.size), armed, skipped);
        }
        void release(region& r)
        {
            if (!r.base.load()) return;
            for (std::uint64_t i = 0; i < r.page_total; ++i)
            {
                auto& p = r.pages[i];
                if (p.state.load() != 1) continue;
                p.state.store(0);
                const auto address = (r.first_page + i) << 12;
                MEMORY_BASIC_INFORMATION m{};
                DWORD old{};
                if (VirtualQuery(reinterpret_cast<void*>(address), &m, sizeof(m)) && m.State == MEM_COMMIT && (m.Protect & 0xFF) == PAGE_READONLY)
                    VirtualProtect(reinterpret_cast<void*>(address), page_size, p.original, &old);
            }
            r.base.store(0);
        }

        std::uint64_t gcd(std::uint64_t a, std::uint64_t b) noexcept { while (b) { const auto t = a % b; a = b; b = t; } return a; }
        void dump()
        {
            if (out_file == INVALID_HANDLE_VALUE) return;
            std::string text;
            char line[600];
            std::snprintf(line, sizeof(line), "# census agents=%u faults=%llu outside=%llu released_pages=%llu sites=%u lost=%u\n", cg_agents, static_cast<unsigned long long>(faults_total.load()),
                static_cast<unsigned long long>(outside_total.load()), static_cast<unsigned long long>(released_total.load()), sites_used.load(), sites_lost.load());
            text += line;
            for (unsigned ri = 0; ri < region_count; ++ri)
            {
                auto& r = regions[ri];
                std::snprintf(line, sizeof(line), "# region %u %s base=0x%llX size=0x%llX\n", ri, r.name, static_cast<unsigned long long>(r.base.load()), static_cast<unsigned long long>(r.size));
                text += line;
                for (std::uint64_t i = 0; i < r.page_total; ++i)
                    if (r.pages[i].state.load() == 2) { std::snprintf(line, sizeof(line), "# released %s +0x%llX\n", r.name, static_cast<unsigned long long>(i << 12)); text += line; }
            }
            text += "region\trip\tcount\tmain\tdistinct\tmin\tmax\tstride\tsample\n";
            for (auto& s : sites)
            {
                const auto key = s.key.load();
                if (!key) continue;
                const auto ri = static_cast<unsigned>((key >> 48) - 1);
                const auto rip = key & 0xFFFFFFFFFFFFull;
                unsigned n = s.distinct.load();
                if (n > sample_count) n = sample_count;
                std::uint32_t v[sample_count];
                for (unsigned i = 0; i < n; ++i) v[i] = s.sample[i].load();
                for (unsigned i = 1; i < n; ++i) for (unsigned j = i; j > 0 && v[j - 1] > v[j]; --j) { const auto t = v[j]; v[j] = v[j - 1]; v[j - 1] = t; }
                std::uint64_t g = 0;
                for (unsigned i = 1; i < n; ++i) g = gcd(g, v[i] - v[i - 1]);
                std::snprintf(line, sizeof(line), "%s\t0x%llX\t%llu\t%llu\t%u\t0x%X\t0x%X\t0x%llX\t", regions[ri < region_count ? ri : 0].name, static_cast<unsigned long long>(rip - game_base),
                    static_cast<unsigned long long>(s.count.load()), static_cast<unsigned long long>(s.main_count.load()), s.distinct.load(), s.min_offset.load(), s.max_offset.load(), static_cast<unsigned long long>(g));
                text += line;
                for (unsigned i = 0; i < n && i < 8; ++i) { std::snprintf(line, sizeof(line), "%s0x%X", i ? "," : "", v[i]); text += line; }
                text += "\n";
            }
            SetFilePointer(out_file, 0, nullptr, FILE_BEGIN);
            DWORD written{};
            WriteFile(out_file, text.data(), static_cast<DWORD>(text.size()), &written, nullptr);
            SetEndOfFile(out_file);
        }
        void helper_main()
        {
            unsigned ticks = 0;
            while (!stop.load())
            {
                Sleep(50);
                if (GetTickCount64() - started_tick < static_cast<std::uint64_t>(delay_seconds) * 1000) continue;
                for (unsigned ri = 0; ri < region_count; ++ri)
                {
                    auto& r = regions[ri];
                    if (!r.is_cg) { if (!r.base.load()) protect(r, r.fixed_base); continue; }
                    const auto object = cg_object();
                    if (object != r.base.load()) { release(r); if (object) { Sleep(200); if (cg_object() == object) protect(r, object); } }
                }
                // a released (hot) page is armed again every 3 s with a fresh fault budget: a writer that only starts after the first 20000 stores of its page is seen in a later window
                if (ticks % 60 == 59)
                    for (unsigned ri = 0; ri < region_count; ++ri)
                        for (std::uint64_t i = 0; i < regions[ri].page_total; ++i)
                        {
                            auto& p = regions[ri].pages[i];
                            if (p.state.load() != 2 || !regions[ri].base.load()) continue;
                            p.faults.store(0);
                            p.state.store(1);
                            DWORD old{};
                            VirtualProtect(reinterpret_cast<void*>((regions[ri].first_page + i) << 12), page_size, PAGE_READONLY, &old);
                        }
                if (++ticks % 100 == 0) dump();
            }
            for (unsigned ri = 0; ri < region_count; ++ri) release(regions[ri]);
            dump();
        }
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
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (game::environment::is_dedi() || !utils::flags::has_flag("paris-write-census") || !utils::flags::has_flag("paris-isolated-lab")) return;
            std::wstring value, number;
            argument(L"-paris-write-census", value);
            if (argument(L"-agent-capacity", number) && !number.empty()) cg_agents = static_cast<unsigned>(_wtoi(number.c_str()));
            if (argument(L"-paris-write-census-limit", number) && !number.empty()) fault_limit = static_cast<unsigned>(_wtoi(number.c_str()));
            if (argument(L"-paris-write-census-delay", number) && !number.empty()) delay_seconds = static_cast<unsigned>(_wtoi(number.c_str()));
            started_tick = GetTickCount64();
            std::string list = value.empty() ? "cg" : std::string(value.begin(), value.end());
            std::size_t start = 0;
            while (start <= list.size() && region_count < max_regions)
            {
                auto end = list.find(',', start);
                if (end == std::string::npos) end = list.size();
                const auto item = list.substr(start, end - start);
                start = end + 1;
                if (item.empty()) continue;
                auto& r = regions[region_count];
                if (item == "cg") { r.is_cg = true; std::snprintf(r.name, sizeof(r.name), "cg"); r.size = cg_size(); }
                else if (item.rfind("abs:", 0) == 0)
                {
                    const auto colon = item.find(':', 4);
                    if (colon == std::string::npos) { console::error("[WC] refused region '%s'\n", item.c_str()); return; }
                    r.fixed_base = std::strtoull(item.substr(4, colon - 4).c_str(), nullptr, 16);
                    r.size = std::strtoull(item.c_str() + colon + 1, nullptr, 0);
                    std::snprintf(r.name, sizeof(r.name), "abs_%llX", static_cast<unsigned long long>(r.fixed_base));
                    if (!r.fixed_base || !r.size || r.size > max_pages * page_size - page_size) { console::error("[WC] refused region '%s'\n", item.c_str()); return; }
                }
                else { console::error("[WC] refused region '%s' (cg | abs:<hex>:<size>)\n", item.c_str()); return; }
                ++region_count;
            }
            if (!region_count) return;
            main_tid.store(GetCurrentThreadId());
            CreateDirectoryW(L"iw7-mod", nullptr);
            CreateDirectoryW(L"iw7-mod\\paris-write-census", nullptr);
            wchar_t name[160]{};
            SYSTEMTIME now{};
            GetSystemTime(&now);
            std::swprintf(name, 160, L"iw7-mod\\paris-write-census\\census-%04u%02u%02u%02u%02u%02u-%lu.tsv", now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond, GetCurrentProcessId());
            out_file = CreateFileW(name, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            enabled = true;
            veh = AddVectoredExceptionHandler(1, handler);
            helper = std::thread(helper_main);
            console::info("[WC] ready: %u region(s), agents=%u, limit %u faults a page, file iw7-mod/paris-write-census\n", region_count, cg_agents, fault_limit);
        }
        void pre_destroy() override
        {
            if (!enabled) return;
            stop.store(true);
            if (helper.joinable()) helper.join();
        }
    };
}

REGISTER_COMPONENT(paris_write_census::component)
