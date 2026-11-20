#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "console/console.hpp"
#include "game/game.hpp"
#include "scheduler.hpp"
#include <utils/flags.hpp>
#include <utils/hook.hpp>
#include <intrin.h>
#include <algorithm>
#include <cstring>
#include <vector>

// Trace census of the agent movement step (a91, 20 Nov 2026): -paris-trace-census.
//
// The native sampler of a joined real-time 200 field (server repository docs/SERVER-FRAME-200.md) put 25 ms of the 50 ms server frame in collision traces under the agent
// step: Pmove FUN_140c5c560 -> path follow FUN_140ae0f80 -> FUN_1403e61b0 -> FUN_14043ec10 -> FUN_1405eb170 (the capsule/box sweep with the entity and agent checks) -> the CM trace
// leaves. This counts, per call site (the return address into the caller) and per server frame: how many times FUN_1405eb170 is called, and the time inside it. Names are made
// offline from the engine map (engine.py at <site>): the function that holds the site says the kind (ground, step-up, forward sweep, agent against agent).
//
// Every 600 server frames (30 s) one block of lines goes to the console log:
//   [Paris trace census] frames=<n> site=0x<addr> calls_per_frame=<x> ms_per_frame=<y> mean_us=<z>
// The stub forwards its seven arguments untouched (the function takes seven integer-class parameters: three on the stack), so its result is the original's.
namespace paris_trace_census
{
    namespace
    {
        constexpr std::uintptr_t sweep_function = 0x1405EB170;
        constexpr std::size_t slots = 512;
        constexpr std::uint64_t window_frames = 600;

        struct row { std::uintptr_t site; std::uint64_t calls; std::int64_t ticks; };
        row table[slots];
        std::uint64_t frames{};
        std::int64_t qpc_hz{};
        std::atomic<DWORD> server_thread{0};
        utils::hook::detour sweep_hook;

        std::int64_t now()
        {
            LARGE_INTEGER v{};
            QueryPerformanceCounter(&v);
            return v.QuadPart;
        }

        std::uint64_t sweep_stub(std::uint64_t a, std::uint64_t b, std::uint64_t c, std::uint64_t d, std::uint64_t e, std::uint64_t f, std::uint64_t g)
        {
            const auto site = reinterpret_cast<std::uintptr_t>(_ReturnAddress());
            const auto thread = GetCurrentThreadId();
            auto expected = DWORD{0};
            server_thread.compare_exchange_strong(expected, thread);
            if (server_thread.load(std::memory_order_relaxed) != thread) return sweep_hook.invoke<std::uint64_t>(a, b, c, d, e, f, g);
            const auto begin = now();
            const auto result = sweep_hook.invoke<std::uint64_t>(a, b, c, d, e, f, g);
            const auto spent = now() - begin;
            auto index = (site >> 2) & (slots - 1);
            for (std::size_t probe = 0; probe < slots; ++probe, index = (index + 1) & (slots - 1))
            {
                if (table[index].site == site || table[index].site == 0)
                {
                    table[index].site = site;
                    ++table[index].calls;
                    table[index].ticks += spent;
                    break;
                }
            }
            return result;
        }

        void report()
        {
            std::vector<row> rows;
            for (const auto& r : table) if (r.site) rows.push_back(r);
            std::sort(rows.begin(), rows.end(), [](const row& x, const row& y) { return x.ticks > y.ticks; });
            std::uint64_t calls = 0;
            std::int64_t ticks = 0;
            for (const auto& r : rows) { calls += r.calls; ticks += r.ticks; }
            console::info("[Paris trace census] frames=%llu total calls_per_frame=%.1f ms_per_frame=%.3f\n", static_cast<unsigned long long>(frames),
                static_cast<double>(calls) / frames, 1000.0 * static_cast<double>(ticks) / static_cast<double>(qpc_hz) / frames);
            for (std::size_t i = 0; i < rows.size() && i < 24; ++i)
            {
                const auto& r = rows[i];
                console::info("[Paris trace census] frames=%llu site=0x%llX calls_per_frame=%.2f ms_per_frame=%.3f mean_us=%.2f\n", static_cast<unsigned long long>(frames),
                    static_cast<unsigned long long>(r.site), static_cast<double>(r.calls) / frames, 1000.0 * static_cast<double>(r.ticks) / static_cast<double>(qpc_hz) / frames,
                    1e6 * static_cast<double>(r.ticks) / static_cast<double>(qpc_hz) / std::max<std::uint64_t>(1, r.calls));
            }
            std::memset(table, 0, sizeof(table));
            frames = 0;
        }

        class component final : public component_interface
        {
        public:
            void post_unpack() override
            {
                if (!game::environment::is_dedi() || !utils::flags::has_flag("paris-trace-census")) return;
                LARGE_INTEGER hz{};
                QueryPerformanceFrequency(&hz);
                qpc_hz = hz.QuadPart;
                sweep_hook.create(sweep_function, sweep_stub);
                scheduler::loop([]
                {
                    if (!server_thread.load()) return;
                    if (++frames >= window_frames) report();
                }, scheduler::server);
                console::info("[Paris trace census] ready: FUN_1405EB170 calls per site, %llu frames a block\n", static_cast<unsigned long long>(window_frames));
            }
        };
    }
}

REGISTER_COMPONENT(paris_trace_census::component)
