#include <std_include.hpp>
#include "collision_provider.hpp"
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "game/scripting/vector.hpp"
#include "component/command.hpp"
#include "component/console/console.hpp"
#include "component/gsc/script_extension.hpp"
#include "component/scheduler.hpp"
#include "component/scripting.hpp"
#include <utils/flags.hpp>
#include <utils/hook.hpp>
#include <utils/cryptography.hpp>
#include <atomic>
#include <charconv>
#include <cstdlib>
#include <mutex>

namespace collision_provider
{
    namespace
    {
        // Bindings derived from the retained IW7 snapshot and checked again at
        // post_unpack. They are experimental until a fresh engine run succeeds.
        game::symbol<void*(void*)> config_ctor{0x1410920E0};
        game::symbol<void*(const strided_vertices*, float, const void*)> convex_factory{0x141092130};
        game::symbol<unsigned int(int)> create_instance{0x14054E080};
        game::symbol<void(int, unsigned int, bool)> destroy_instance{0x14054E750};
        game::symbol<game::PhysicsAsset*(const char*)> find_asset_by_name{0x14054EC30};
        game::symbol<void*(const game::PhysicsAsset*)> lookup_asset_context{0x140578C00};
        game::symbol<bool(unsigned int, int, game::PhysicsAsset*, unsigned int, unsigned int,
            const float*, const float*, bool, bool, bool, float, float, int, int, bool)> instantiate_capsule{0x14054FBD0};
        game::symbol<void(int, unsigned int, int)> set_contents{0x140550EC0};
        game::symbol<bool(unsigned int, void*, const float*, const float*, const game::Bounds*, int,
            int, int, int, void*, int)> legacy_trace{0x14055C9E0};

        utils::hook::detour capsule_factory_hook;
        struct replacement { void* shape{}; unsigned int consumed{}; };
        thread_local replacement* pending{};
        struct replacement_scope
        {
            replacement& request;
            explicit replacement_scope(replacement& value) : request(value) { pending = &value; }
            ~replacement_scope() { pending = nullptr; remove_unused(); }
            void remove_unused();
        };
        struct instance
        {
            int world, entity;
            unsigned int id;
            box geometry;
            game::PhysicsAsset* body_template;
        };
        std::recursive_mutex mutex;
        std::vector<instance> instances;

        bool readable(const void* pointer, std::size_t size)
        {
            MEMORY_BASIC_INFORMATION region{};
            if (!pointer || !VirtualQuery(pointer, &region, sizeof(region)) || region.State != MEM_COMMIT ||
                region.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return false;
            const auto address = reinterpret_cast<std::uintptr_t>(pointer);
            const auto begin = reinterpret_cast<std::uintptr_t>(region.BaseAddress);
            return address >= begin && address - begin <= region.RegionSize && size <= region.RegionSize - (address - begin);
        }

        bool world_ready(int world)
        {
            if (!world_permitted(game::environment::is_dedi(), world)) return false;
            const auto location = reinterpret_cast<void**>(0x144BDF5A0 + static_cast<std::uintptr_t>(world) * 0x358 + 0x30);
            return readable(location, sizeof(void*)) && readable(*location, sizeof(void*));
        }

        bool readable_template_name(const char* name)
        {
            // Bound this laboratory input before the retail byte comparator.
            // This is a local validation limit, not a claimed engine name limit.
            if (!name) return false;
            for (std::size_t index = 0; index < 256; ++index)
            {
                if (!readable(name + index, 1)) return false;
                if (!name[index]) return index != 0;
            }
            return false;
        }

        bool session_ready()
        {
            if (!game::environment::is_dedi()) return false;
            const auto* lan = game::Dvar_FindVar("sv_lanOnly");
            const auto* password = game::Dvar_FindVar("g_password");
            const auto* bind = game::Dvar_FindVar("net_ip");
            return game::SV_Loaded() && lan && lan->type == game::DVAR_TYPE_BOOL && lan->current.enabled &&
                password && password->type == game::DVAR_TYPE_STRING && password->current.string && *password->current.string &&
                bind && bind->type == game::DVAR_TYPE_STRING && bind->current.string && !std::strcmp(bind->current.string, "127.0.0.1");
        }

        void remove_reference(void* shape)
        {
            if (!shape) return;
            auto* count = reinterpret_cast<std::uint32_t*>(static_cast<char*>(shape) + 8);
            if (!(*count >> 16)) return;
            std::atomic_ref<std::uint32_t> atomic(*count);
            auto previous = atomic.load();
            std::uint32_t next;
            do { next = (previous & 0xffff0000U) | static_cast<std::uint16_t>(previous - 1); }
            while (!atomic.compare_exchange_weak(previous, next));
            if (!(next & 0xffff))
            {
                const auto table = *reinterpret_cast<void***>(shape);
                reinterpret_cast<void(*)(void*)>(table[3])(shape);
            }
        }

        void replacement_scope::remove_unused() { remove_reference(request.shape); request.shape = nullptr; }

        void* capsule_factory(const float* center, float half_height, float radius, int segments, bool cache)
        {
            if (pending)
            {
                ++pending->consumed;
                if (pending->shape)
                {
                    auto* result = pending->shape;
                    pending->shape = nullptr;
                    return result;
                }
            }
            return capsule_factory_hook.invoke<void*>(center, half_height, radius, segments, cache);
        }

        unsigned int add_box(int world, int entity, const box& geometry)
        {
            std::lock_guard lock(mutex);
            if (!session_ready() || !world_ready(world) || entity < 0 || entity >= 2046 || pending)
                throw std::runtime_error("Collision provider requires a ready owned world and a script entity reference");
            if (game::environment::is_dedi())
            {
                const auto& target = game::g_entities[entity];
                const char* classname = game::SL_ConvertToString(target.classname);
                if (target.client || target.agent || !classname || std::strcmp(classname, "script_model"))
                    throw std::runtime_error("A dedicated script_model reference is required");
                int contents{};
                std::memcpy(&contents, reinterpret_cast<const char*>(&target) + 0x130, sizeof(contents));
                const auto linked = *(reinterpret_cast<const unsigned char*>(&target) + 0x110);
                std::uint32_t producer_class_word{};
                std::memcpy(&producer_class_word, reinterpret_cast<const char*>(&target) + 0x1a8, sizeof(producer_class_word));
                // Probe B qualified the retail script_model mask0x2080 branch.
                // Read its current producer IDs; observed VM IDs are not constants
                // and unknown IDs are never passed to SL_ConvertToString.
                const auto* no_change_class = reinterpret_cast<const game::scr_string_t*>(0x145D5B070);
                const auto* mask_2080_class = reinterpret_cast<const game::scr_string_t*>(0x145D5B06C);
                if (!readable(no_change_class, sizeof(*no_change_class)) || !readable(mask_2080_class, sizeof(*mask_2080_class)))
                    throw std::runtime_error("Retail solid producer class data is unreadable; preserve the entity");
                console::info("[Collision provider] solid_admission world=%d entity=%d sdk_classname=%s sdk_classname_id=%u sdk_classname_offset=%zu producer_class_word_1a8=%u contents_word_130=0x%08x linked_byte_110=%u no_change_class_id=%u mask_2080_class_id=%u\n",
                    world, entity, classname, static_cast<unsigned int>(target.classname), offsetof(game::gentity_s, classname), producer_class_word, static_cast<unsigned int>(contents),
                    static_cast<unsigned int>(linked), static_cast<unsigned int>(*no_change_class), static_cast<unsigned int>(*mask_2080_class));
                if (!owner_solid_permitted(static_cast<std::uint32_t>(contents), linked,
                    producer_class_word, target.classname, *mask_2080_class, *no_change_class))
                    throw std::runtime_error("Call the retail solid() method on the script_model before creating its box");
            }
            // Retail56C650 passes54EC30(*slot), not the raw slot, to capsule arg3.
            const auto* name_slot = reinterpret_cast<const char* const*>(0x141BA4500);
            if (!readable(name_slot, sizeof(*name_slot)))
                throw std::runtime_error("Retail default body template name is unreadable");
            const auto* name = *name_slot;
            if (!readable_template_name(name))
                throw std::runtime_error("Retail default body template name is unreadable");
            auto* asset = resolve_body_template(name,
                [](const char* name) { return find_asset_by_name(name); },
                [](const game::PhysicsAsset* value) {
                    return readable(value, sizeof(*value)) && value->numRigidBodies >= 1 && value->havokData;
                },
                [](const game::PhysicsAsset* value) {
                    const auto* context = lookup_asset_context(value);
                    return readable(context, 0x68); // Includes the retained dereference at+0x60.
                });
            // This non-mutating preflight refuses the known null-context path;
            // it does not lock the engine table through subsequent instantiation.
            // Allocate the record before an engine side effect, avoiding a vector
            // allocation failure after a successfully created physics instance.
            instances.reserve(instances.size() + 1);
            alignas(16) std::array<unsigned char, 0x38> config{};
            config_ctor(config.data());
            const float zero = 0;
            std::memcpy(config.data(), &zero, sizeof(zero));
            config[4] = 0; // Same choices as the retail capsule factory.
            const strided_vertices input{geometry.vertices.data(), 8, 16};
            replacement request{convex_factory(&input, 0.0f, config.data()), 0};
            if (!request.shape) throw std::runtime_error("Native Havok convex factory refused the box");
            const auto id = create_instance(world);
            if (id == 0xffffffffU)
            {
                remove_reference(request.shape);
                throw std::runtime_error("Native physics instance allocation failed");
            }
            bool created = false;
            const std::array<float, 4> rotation{0, 0, 0, 1};
            {
                replacement_scope scope(request);
                // Reference system 0 is decoded to world entity 2046 by
                // 54F040's switch table. The script entity owns teardown.
                created = instantiate_capsule(id, world, asset, 0, 0,
                    geometry.origin.data(), rotation.data(), true, true, false, 1.0f, 1.0f, 1, 0, false);
            }
            if (!created || request.consumed != 1)
            {
                destroy_instance(world, id, true);
                throw std::runtime_error("Native body creation did not consume exactly one original box shape");
            }
            set_contents(world, id, 1);
            if (world < 2) ++asset->physicsUsageCounter.serverEnt;
            else ++asset->physicsUsageCounter.clientEnt;
            instances.push_back({world, entity, id, geometry, asset});
            console::info("[Collision provider] created world=%d entity=%d instance=%u original_vertices=8 contents=1 template=%s\n",
                world, entity, id, asset->name ? asset->name : "<unnamed>");
            return id;
        }

        void clear_boxes(int entity = -1)
        {
            std::lock_guard lock(mutex);
            for (auto it = instances.begin(); it != instances.end();)
            {
                if (entity >= 0 && it->entity != entity) { ++it; continue; }
                if (!world_ready(it->world))
                    throw std::runtime_error("Physics world closed before owned collision teardown");
                destroy_instance(it->world, it->id, true);
                if (it->world < 2) --it->body_template->physicsUsageCounter.serverEnt;
                else --it->body_template->physicsUsageCounter.clientEnt;
                console::info("[Collision provider] destroyed world=%d entity=%d instance=%u\n", it->world, it->entity, it->id);
                it = instances.erase(it);
            }
        }

        void probe(int world, unsigned int id)
        {
            std::lock_guard lock(mutex);
            const auto found = std::find_if(instances.begin(), instances.end(), [=](const instance& item) { return item.world == world && item.id == id; });
            if (found == instances.end() || !world_ready(world)) throw std::runtime_error("Owned live collision instance required");
            const auto& shape = found->geometry;
            const point point_start{shape.origin[0], shape.origin[1], shape.maximum[2] + 80};
            const point point_end{shape.origin[0], shape.origin[1], shape.maximum[2] - 80};
            const point sweep_end{shape.origin[0], shape.origin[1], shape.maximum[2] + 20};
            const auto query = [&](const char* name, const point& end, const game::Bounds& bounds)
            {
                // FX supplies trace_t plus 16 bytes: the engine writes beyond
                // the SDK trace_t, including a float at 0x40.
                alignas(16) std::array<unsigned char, 128> result{};
                legacy_trace(world, result.data(), point_start.data(), end.data(), &bounds, 2047, 0, 1, 0, nullptr, 0);
                game::trace_t trace{};
                std::memcpy(&trace, result.data(), sizeof(trace));
                console::info("[Collision provider] engine_query=%s world=%d instance=%u fraction=%.9f normal=%.6f,%.6f,%.6f contents=%d hitType=%d hitId=%u startsolid=%d allsolid=%d\n",
                    name, world, id, trace.fraction, trace.normal[0], trace.normal[1], trace.normal[2], trace.contents,
                    static_cast<int>(trace.hitType), trace.hitId, trace.startsolid, trace.allsolid);
            };
            query("point_floor", point_end, game::Bounds{});
            game::Bounds actor{};
            actor.halfSize[0] = 15; actor.halfSize[1] = 15; actor.halfSize[2] = 36;
            query("actor_floor", sweep_end, actor);
        }

        float number(const char* text)
        {
            char* end{};
            const auto value = std::strtof(text, &end);
            if (end == text || *end || !std::isfinite(value)) throw std::runtime_error("Finite numeric collision argument required");
            return value;
        }

        template <typename T> T integer(const char* text)
        {
            T value{};
            const auto end = text + std::strlen(text);
            const auto result = std::from_chars(text, end, value);
            if (result.ec != std::errc{} || result.ptr != end)
                throw std::runtime_error("Exact integer collision argument required");
            return value;
        }

        void verify_bindings()
        {
            const auto check = [](std::uintptr_t address, std::initializer_list<unsigned char> bytes)
            {
                if (!readable(reinterpret_cast<void*>(address), bytes.size()) ||
                    !std::equal(bytes.begin(), bytes.end(), reinterpret_cast<unsigned char*>(address)))
                    throw std::runtime_error("Collision provider engine signature differs");
            };
            check(0x140574550, {0x48,0x8b,0xc4,0x44,0x89,0x48,0x20});
            check(0x141092130, {0x48,0x89,0x5c,0x24,0x08,0x55,0x56,0x57});
            check(0x1410920E0, {0xc7,0x41,0x18,0x00,0x00,0x7a,0xc4});
            check(0x14054FBD0, {0x40,0x53,0x55,0x56,0x57});
            check(0x14054E080, {0xe9,0x3b,0x5c,0x02,0x00});
            check(0x14054E750, {0xe9,0x2b,0x80,0x02,0x00});
            check(0x14054EC30, {0xe9,0xdb,0x8d,0x02,0x00});
            // E's PUSH RDI spans two bytes. Bind the exact admitted body hash
            // instead of guessing its prefix from a mnemonic-only transcript.
            const auto* name_resolver_body = reinterpret_cast<const std::uint8_t*>(0x140577A10);
            if (!readable(name_resolver_body, 241) ||
                _stricmp(utils::cryptography::sha256::compute(name_resolver_body, 241, true).c_str(),
                    "a61124d54fb0eb5cbd9c2c8e3ace99380ee86ded6f0b809dbdde172ddd207f0b"))
                throw std::runtime_error("Retained retail name resolver body hash differs; preserve diagnostics");
            check(0x140578C00, {0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x74,0x24,0x18});
            check(0x14055C9E0, {0x4c,0x8b,0xdc,0x48,0x83,0xec,0x78});
            check(0x140550EC0, {0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x6c});
            // Bind the diagnostic globals to their retained retail producers,
            // rather than treating their absolute addresses as a live ABI.
            check(0x140B60AC0, {0x8b,0x05,0xaa,0xa5,0x1f,0x05});
            check(0x140B60AD2, {0x8b,0x05,0x94,0xa5,0x1f,0x05});
            check(0x140C6D552, {0xc6,0x83,0x10,0x01,0x00,0x00,0x01});
            static_assert(sizeof(game::PhysicsAsset) == 0x50);
            static_assert(offsetof(game::PhysicsAsset, physicsUsageCounter) == 0x40);
            static_assert(sizeof(game::trace_t) <= 112);
        }
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (!utils::flags::has_flag("paris-collision-provider")) return;
            if (!utils::flags::has_flag("paris-isolated-lab")) throw std::runtime_error("Collision provider requires the isolated laboratory flag");
            if (!game::environment::is_dedi())
            {
                console::info("[Collision provider] client creation disabled until private endpoint and pre-reset world lifetime are qualified\n");
                return;
            }
            verify_bindings();
            capsule_factory_hook.create(0x140574550, capsule_factory);
            command::add("collision_box_create", [](const command::params& args)
            {
                try
                {
                    if (args.size() != 9) throw std::runtime_error("Usage: collision_box_create world entity minX minY minZ maxX maxY maxZ");
                    const auto world = integer<int>(args[1]);
                    const auto entity = integer<int>(args[2]);
                    const auto geometry = make_box({number(args[3]),number(args[4]),number(args[5])}, {number(args[6]),number(args[7]),number(args[8])});
                    scheduler::once([=] { try { (void)add_box(world, entity, geometry); } catch (const std::exception& error) { console::error("[Collision provider] %s\n", error.what()); } },
                        game::environment::is_dedi() ? scheduler::server : scheduler::main);
                }
                catch (const std::exception& error) { console::error("[Collision provider] %s\n", error.what()); }
            });
            command::add("collision_box_probe", [](const command::params& args)
            {
                try
                {
                    if (args.size() != 3) throw std::runtime_error("Usage: collision_box_probe world instance");
                    const auto world = integer<int>(args[1]);
                    const auto id = integer<unsigned int>(args[2]);
                    scheduler::once([=] { try { probe(world, id); } catch (const std::exception& error) { console::error("[Collision provider] %s\n", error.what()); } },
                        game::environment::is_dedi() ? scheduler::server : scheduler::main);
                }
                catch (const std::exception& error) { console::error("[Collision provider] %s\n", error.what()); }
            });
            command::add("collision_box_clear", [] { scheduler::once([] { try { clear_boxes(); } catch (const std::exception& error) { console::error("[Collision provider] %s\n", error.what()); } },
                game::environment::is_dedi() ? scheduler::server : scheduler::main); });
            gsc::method::add("collision_createbox", [](game::scr_entref_t entity, const gsc::function_args& args) -> scripting::script_value
            {
                if (!game::environment::is_dedi() || entity.classnum || args.size() != 2)
                    throw std::runtime_error("Dedicated script-model collision_createbox(minimum, maximum) required");
                const auto* target = game::GetEntity(entity);
                const auto* classname = target ? game::SL_ConvertToString(target->classname) : nullptr;
                if (!target || target->client || target->agent ||
                    !classname || std::strcmp(classname, "script_model"))
                    throw std::runtime_error("An owned static script_model is required");
                const auto a = args[0].as<scripting::vector>(), b = args[1].as<scripting::vector>();
                const auto geometry = make_box({a.get_x(),a.get_y(),a.get_z()}, {b.get_x(),b.get_y(),b.get_z()});
                return static_cast<int>(add_box(0, entity.entnum, geometry));
            });
            gsc::method::add("collision_clearboxes", [](game::scr_entref_t entity, const gsc::function_args&) -> scripting::script_value
            {
                if (!game::environment::is_dedi() || entity.classnum) throw std::runtime_error("Dedicated entity required");
                clear_boxes(entity.entnum);
                return {};
            });
            scripting::on_shutdown([](bool, bool post)
            {
                if (!post && game::environment::is_dedi())
                {
                    try { clear_boxes(); }
                    catch (const std::exception& error) { console::error("[Collision provider] shutdown teardown refused: %s\n", error.what()); }
                }
            });
            console::info("[Collision provider] experimental native convex box factory installed; no runtime or player acceptance yet\n");
        }
    };
}

REGISTER_COMPONENT(collision_provider::component)
