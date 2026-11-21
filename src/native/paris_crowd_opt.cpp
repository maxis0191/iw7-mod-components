#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "console/console.hpp"
#include "game/game.hpp"
#include "gsc/script_extension.hpp"
#include "scheduler.hpp"
#include "scripting.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

namespace paris_crowd_opt
{
    namespace
    {
        constexpr auto method_index = 0x84B5 - 0x8000;
        constexpr std::uintptr_t stock_address = 0x1403E1EC0;
        const auto stock_tick = reinterpret_cast<gsc::builtin_method>(stock_address);
        static_assert(method_index < gsc::meth_table_count);

        constexpr std::size_t entity_count = 2048;
        constexpr unsigned player_slots = 8;
        constexpr unsigned first_agent_slot = 18;
        constexpr double near_sq = 600.0 * 600.0;
        constexpr double far_sq = 900.0 * 900.0;

        using origin = std::array<float, 3>;
        static_assert(sizeof(game::gentity_s) == 0x3F8);
        static_assert(offsetof(game::gentity_s, s) + offsetof(game::entityState_t, number) == 0);
        static_assert(offsetof(game::gentity_s, client) == 0x170);

        // CP retail layout. The SDK gentity_s pads these fields or names other fields at these offsets.
        constexpr std::size_t origin_offset = 0x14C;     // PlayerCmd_getorigin
        constexpr std::size_t agent_offset = 0x190;      // PlayerCmd_finishagentdamage
        constexpr std::size_t health_offset = 0x1E0;     // GScr_isalive, PlayerCmd_finishagentdamage
        constexpr std::size_t generation_offset = 0x30C; // entity teardown 0x140B665E0 and G_RunFrame
        constexpr std::uintptr_t in_use_address = 0x143CA1600; // byte per slot, G_RunFrame
        constexpr std::uintptr_t agent_pool_address = 0x143C986B8;
        constexpr std::uintptr_t agent_count_address = 0x143C986C0;
        constexpr std::size_t agent_stride = 0x5010;     // G_RunFrame, agent-index check at 0x140C13D20
        constexpr std::size_t agent_entnum = 0x4A90;
        constexpr std::size_t damage_event = 0x22C;      // damage feedback at 0x140C167E0
        constexpr std::size_t pending_damage = 0x4CCC;   // PlayerCmd_finishagentdamage and 0x140C167E0

        struct agent_state
        {
            int last_time = -1;
            int wake_time = -1;
            int health = 0;
            std::uint32_t generation = 0;
            std::uint32_t damage = 0;
            bool distant = false;
        };

        struct tick_measurement
        {
            std::uint64_t total = 0;
            std::uint64_t eligible = 0;
            std::uint64_t distant = 0;
            double total_qpc = 0;
            double eligible_qpc = 0;
            double distant_qpc = 0;
            unsigned frames = 0;
        };

        const game::dvar_t* setting = nullptr;
        std::atomic<DWORD> server_thread{0};
        std::atomic<bool> map_shutdown{false};
        // Everything below is confined to the server pipeline and its VM calls.
        std::array<agent_state, entity_count> agents{};
        tick_measurement meter{};
        std::int64_t qpc_hz = 0;
        int active_mode = 0;
        int last_level_time = -1;
        bool mismatch_logged = false;

        template <typename T> T read_field(const void* base, const std::size_t offset)
        {
            T value{};
            std::memcpy(&value, static_cast<const unsigned char*>(base) + offset, sizeof(value));
            return value;
        }

        bool in_use(const unsigned slot)
        {
            return reinterpret_cast<const unsigned char*>(in_use_address)[slot] != 0;
        }

        bool finite(const origin& point)
        {
            return std::all_of(point.begin(), point.end(), [](float value) { return std::isfinite(value); });
        }

        double nearest_player_sq(const origin& from)
        {
            const auto* clients = *game::svs_clients;
            if (!clients || !finite(from)) return 0.0;

            double nearest = std::numeric_limits<double>::infinity();
            const auto slots = std::min(*game::svs_numclients, player_slots);
            for (unsigned i = 0; i < slots; ++i)
            {
                const auto& connection = clients[i];
                if (connection.header.state != game::CS_ACTIVE) continue;

                const auto& player = game::g_entities[i];
                if (connection.gentity != &player || !in_use(i) || !player.client) return 0.0;
                if (player.client->sess.sessionState != game::SESS_STATE_PLAYING ||
                    read_field<int>(&player, health_offset) <= 0) continue;

                const auto to = read_field<origin>(&player, origin_offset);
                if (!finite(to)) return 0.0;
                const double dx = static_cast<double>(to[0]) - from[0];
                const double dy = static_cast<double>(to[1]) - from[1];
                const double dz = static_cast<double>(to[2]) - from[2];
                nearest = std::min(nearest, dx * dx + dy * dy + dz * dz);
                if (nearest < near_sq) break;
            }

            // No live player means there is no distance proof for a skipped tick.
            return std::isfinite(nearest) ? nearest : 0.0;
        }

        void reset_level()
        {
            agents.fill(agent_state{});
            meter = {};
            last_level_time = -1;
        }

        void observe_time(const int now)
        {
            if (now < last_level_time) reset_level();
            last_level_time = now;
        }

        double classify(const game::scr_entref_t ref, const int now)
        {
            const unsigned slot = ref.entnum;
            if (ref.classnum != 0 || slot < first_agent_slot || slot >= entity_count - 2 || now < 0) return 0.0;

            auto& state = agents[slot];
            const auto& entity = game::g_entities[slot];
            const unsigned index = slot - first_agent_slot;
            const auto count = *reinterpret_cast<const unsigned*>(agent_count_address);
            const auto pool = *reinterpret_cast<const std::uintptr_t*>(agent_pool_address);
            const auto agent = read_field<std::uintptr_t>(&entity, agent_offset);
            const auto health = read_field<int>(&entity, health_offset);
            if (!in_use(slot) || entity.client || read_field<unsigned>(&entity, 0) != slot || health <= 0 ||
                count > entity_count - first_agent_slot || index >= count || !pool ||
                agent != pool + index * agent_stride)
            {
                state = {};
                return 0.0;
            }

            const auto* record = reinterpret_cast<const void*>(agent);
            if (read_field<unsigned>(record, agent_entnum) != slot ||
                read_field<int>(record, offsetof(game::playerState_s, pm_type)) != game::PM_NORMAL)
            {
                state = {};
                return 0.0;
            }

            const auto generation = read_field<std::uint32_t>(&entity, generation_offset);
            const auto damage = read_field<std::uint32_t>(record, damage_event);
            const auto pending = read_field<std::array<int, 2>>(record, pending_damage);
            const bool wake = state.last_time < 0 || now - state.last_time > 200 ||
                generation != state.generation || health < state.health || damage != state.damage ||
                pending[0] != 0 || pending[1] != 0;

            state.last_time = now;
            state.generation = generation;
            state.health = health;
            state.damage = damage;
            if (wake) state.wake_time = now;
            if (state.wake_time == now)
            {
                state.distant = false;
                return 0.0;
            }

            const auto distance = nearest_player_sq(read_field<origin>(&entity, origin_offset));
            if (distance > far_sq) state.distant = true;
            if (distance < near_sq) state.distant = false;
            return distance;
        }

        std::int64_t qpc()
        {
            LARGE_INTEGER value{};
            return QueryPerformanceCounter(&value) ? value.QuadPart : 0;
        }

        void tick_wrapper(const game::scr_entref_t ref)
        {
            if (server_thread.load(std::memory_order_relaxed) != GetCurrentThreadId() ||
                map_shutdown.load(std::memory_order_acquire))
            {
                stock_tick(ref);
                return;
            }

            const auto now = *game::gameTime;
            observe_time(now);
            const auto distance = classify(ref, now);
            if (active_mode == 1)
            {
                const bool eligible = distance >= near_sq;
                const bool distant = distance > far_sq;
                ++meter.total;
                if (eligible) ++meter.eligible;
                if (distant) ++meter.distant;
                const auto begin = qpc();
                stock_tick(ref);
                const auto end = qpc();
                if (begin > 0 && end >= begin)
                {
                    const auto elapsed = static_cast<double>(end - begin);
                    meter.total_qpc += elapsed;
                    if (eligible) meter.eligible_qpc += elapsed;
                    if (distant) meter.distant_qpc += elapsed;
                }
                return;
            }

            // bttick's stock handler returns void and does not push a result to the VM.
            const auto phase = now / 50 + static_cast<int>(ref.entnum);
            const auto stride = active_mode == 3 && distance > far_sq ? 4 : 2;
            const bool eligible = distance >= near_sq &&
                (active_mode == 3 || (active_mode == 2 && agents[ref.entnum].distant));
            if (!eligible || phase % stride == 0) stock_tick(ref);
        }

        void server_frame()
        {
            const int requested = setting && setting->type == game::DVAR_TYPE_INT ? setting->current.integer : 0;
            const int mode = requested >= 1 && requested <= 3 && game::SV_Loaded() &&
                game::Com_GameMode_GetActiveGameMode() == game::GAME_MODE_CP ? requested : 0;
            auto& slot = gsc::meth_table[method_index];
            const bool reset = map_shutdown.exchange(false, std::memory_order_acq_rel);
            if (mode == 0)
            {
                if (slot == tick_wrapper) slot = stock_tick;
                if (active_mode != 0 || reset) reset_level();
                active_mode = 0;
                return;
            }

            server_thread.store(GetCurrentThreadId(), std::memory_order_relaxed);
            if (slot != tick_wrapper)
            {
                reset_level();
                active_mode = 0;
                if (slot != stock_tick)
                {
                    if (!mismatch_logged)
                    {
                        mismatch_logged = true;
                        console::error("[paris_crowd_opt] unexpected bttick handler %p (expected 0x1403E1EC0)\n",
                            reinterpret_cast<void*>(slot));
                    }
                    return;
                }
                slot = tick_wrapper;
            }

            if (mode != active_mode || reset)
            {
                reset_level();
                active_mode = mode;
                if (mode == 1)
                {
                    LARGE_INTEGER frequency{};
                    qpc_hz = QueryPerformanceFrequency(&frequency) ? frequency.QuadPart : 0;
                }
                return;
            }

            observe_time(*game::gameTime);
            if (mode != 1 || ++meter.frames < 200) return;

            const double us_per_count = qpc_hz > 0 ? 1e6 / static_cast<double>(qpc_hz) : 0.0;
            console::info("[paris_crowd_opt] frames=%u total=%llu eligible=%llu distant=%llu stock_us=%.1f eligible_us=%.1f distant_us=%.1f\n",
                meter.frames, static_cast<unsigned long long>(meter.total), static_cast<unsigned long long>(meter.eligible),
                static_cast<unsigned long long>(meter.distant), meter.total_qpc * us_per_count, meter.eligible_qpc * us_per_count,
                meter.distant_qpc * us_per_count);
            meter = {};
        }
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (!game::environment::is_dedi()) return;

            scripting::on_shutdown([](bool, bool)
            {
                map_shutdown.store(true, std::memory_order_release);
            });
            scheduler::once([]
            {
                setting = game::Dvar_RegisterInt("paris_native_crowd_opt", 0, 0, 3, game::DVAR_FLAG_NONE,
                    "Dedicated CP behavior-tree ticks: 0 off, 1 measure, 2 distant 10 Hz, 3 distant 5 Hz");
                scheduler::loop(server_frame, scheduler::server);
            }, scheduler::main);
        }
    };
}

REGISTER_COMPONENT(paris_crowd_opt::component)
