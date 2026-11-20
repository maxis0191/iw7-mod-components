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
#include <utility>
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
            const auto begin = now();
            const auto result = sweep_hook.invoke<std::uint64_t>(a, b, c, d, e, f, g);
            const auto spent = now() - begin;
            auto index = (site >> 2) & (slots - 1);
            for (std::size_t probe = 0; probe < slots; ++probe, index = (index + 1) & (slots - 1))
            {
                auto* key = reinterpret_cast<volatile LONG64*>(&table[index].site);
                const auto seen = InterlockedCompareExchange64(key, static_cast<LONG64>(site), 0);
                if (seen == 0 || static_cast<std::uintptr_t>(seen) == site)
                {
                    InterlockedIncrement64(reinterpret_cast<volatile LONG64*>(&table[index].calls));
                    InterlockedAdd64(reinterpret_cast<volatile LONG64*>(&table[index].ticks), spent);
                    break;
                }
            }
            return result;
        }

        // Inclusive time and call count of a few functions above the sweep, to put the sweep's share in the frame (the native sampler's stack attribution is a claim until a hook measures it).
        struct slot { DWORD tid; std::uint64_t calls; std::int64_t ticks; };
        struct timer_row { const char* name; std::uintptr_t address; slot slots[8]; utils::hook::detour hook; };
        timer_row timers[] = {
            {"FUN_140c1a3f0 agent iteration", 0x140C1A3F0, {}, {}},
            {"FUN_140c5c560 Pmove", 0x140C5C560, {}, {}},
            {"FUN_140c5ef00 agent step", 0x140C5EF00, {}, {}},
            {"FUN_1403e61b0 path follow", 0x1403E61B0, {}, {}},
            {"FUN_1403e5700 path trace", 0x1403E5700, {}, {}},
            {"FUN_14043ec10 two-point trace", 0x14043EC10, {}, {}},
        };

        template <std::size_t I>
        std::uint64_t timer_stub(std::uint64_t a, std::uint64_t b, std::uint64_t c, std::uint64_t d, std::uint64_t e, std::uint64_t f, std::uint64_t g)
        {
            const auto thread = GetCurrentThreadId();
            const auto begin = now();
            const auto result = timers[I].hook.invoke<std::uint64_t>(a, b, c, d, e, f, g);
            const auto spent = now() - begin;
            for (auto& sl : timers[I].slots)
            {
                if (sl.tid == thread || InterlockedCompareExchange(reinterpret_cast<volatile LONG*>(&sl.tid), static_cast<LONG>(thread), 0) == 0)
                {
                    ++sl.calls;
                    sl.ticks += spent;
                    break;
                }
            }
            return result;
        }

        template <std::size_t... Is>
        void install_timers(std::index_sequence<Is...>)
        {
            (timers[Is].hook.create(timers[Is].address, timer_stub<Is>), ...);
        }

        void report()
        {
            for (auto& t : timers)
            {
                for (auto& sl : t.slots)
                {
                    if (!sl.tid) continue;
                    console::info("[Paris trace census] frames=%llu timer=%s thread=%lu%s calls_per_frame=%.2f ms_per_frame=%.3f\n", static_cast<unsigned long long>(frames), t.name,
                        static_cast<unsigned long>(sl.tid), sl.tid == server_thread.load() ? " (frame loop thread)" : "", static_cast<double>(sl.calls) / frames,
                        1000.0 * static_cast<double>(sl.ticks) / static_cast<double>(qpc_hz) / frames);
                    sl.calls = 0;
                    sl.ticks = 0;
                }
            }
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
                install_timers(std::make_index_sequence<6>{});
                scheduler::loop([]
                {
                    server_thread.store(GetCurrentThreadId());
                    if (++frames >= window_frames) report();
                }, scheduler::server);
                console::info("[Paris trace census] ready: FUN_1405EB170 calls per site, %llu frames a block\n", static_cast<unsigned long long>(window_frames));
            }
        };
    }
}

REGISTER_COMPONENT(paris_trace_census::component)
