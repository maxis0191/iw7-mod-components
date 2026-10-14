#include <std_include.hpp>
#include "paris_model_diagnostics.hpp"
#include "agent_scenario.hpp"
#include "paris_test_safety.hpp"
#include "game/game.hpp"
#include "console/console.hpp"
#include "component/scheduler.hpp"
#include <utils/flags.hpp>
#include <cstring>
#include <limits>
#include <array>
#include <atomic>
#include <mutex>
#include <type_traits>

namespace paris_model_diagnostics
{
    namespace
    {
        // The pinned IW7 SDK database layout matches ZoneTool fab9358.
        static_assert(sizeof(game::XModel) == 0x2E0);
        static_assert(offsetof(game::XModel, lodInfo) == 0xE0);
        static_assert(sizeof(game::XModelLodInfo) == 0x40);
        static_assert(sizeof(game::XModelSurfs) == 0x38);
        static_assert(offsetof(game::XModelSurfs, surfs) == 0x08);
        static_assert(offsetof(game::XModelSurfs, numsurfs) == 0x10);
        static_assert(sizeof(game::XSurface) == 0x100);
        static_assert(offsetof(game::XSurface, verts0) == 0x20);
        static_assert(offsetof(game::XSurface, vb0) == 0x30);
        static_assert(offsetof(game::XSurface, blendVertSize) == 0x18);
        static_assert(offsetof(game::XSurface, rigidVertLists) == 0x48);
        static_assert(offsetof(game::XSurface, blendVerts) == 0x50);
        static_assert(offsetof(game::XSurface, blendVertsBuffer) == 0x58);
        static_assert(offsetof(game::XSurface, blendVertsView) == 0x60);
        static_assert(sizeof(game::NetConstStrings) == 0x20);
        static_assert(offsetof(game::NetConstStrings, stringList) == 0x18);
        static_assert(offsetof(game::Material, techniqueSet) == 0x38);
        static_assert(sizeof(game::Material) == 0x118);
        static_assert(offsetof(game::XModel, materialHandles) == 0xD8);
        static_assert(sizeof(game::GfxSceneModel) <= 256);
        static_assert(std::is_trivially_copyable_v<game::GfxSceneModel>);
        static_assert(std::extent_v<decltype(game::GfxScene::sceneModel)> == 1024);
        constexpr const char* scene_keys[]{"paris_doom_skin_two_bone_first_a", "paris_doom_skin_two_bone_second_a", "zmb_coin_alien"};
        std::string observed_nonce, observed_generation, observed_challenge;
        profile observed_profile = profile::none;
        std::uint64_t observation_sequence{}; // Main-thread observation ID, not a loader invocation.

        enum class scene_status { pending, sampled, cancelled, expired, count_refused, read_fault, budget_refused };
        struct scene_row
        {
            int model{}, index{};
            unsigned entnum{}, render_flags{}, lod{}, material_lod{}, surface_bytes{}, surface_id{};
            bool obj_present{};
            float origin[3]{}, quat[4]{}, scale{}, radius{};
        };
        struct scene_result
        {
            scene_status status{scene_status::pending};
            int before{-1}, after{-1};
            unsigned records{}, matches[3]{};
            bool truncated{};
            std::uint64_t started_tick{}, sampled_tick{};
            std::array<scene_row, 8> rows{};
        };
        struct scene_request
        {
            std::mutex mutex;
            scene_permit permit{};
            std::string nonce, generation, challenge;
            std::array<std::uintptr_t, 3> models{};
            scene_result result{};
            std::uint64_t consumed_arm{}, requested_tick{};
            bool pending{};
        };
        // Process-lifetime request storage prevents teardown callbacks from
        // touching a destroyed mutex. Allocated only for the explicit profile.
        std::atomic<scene_request*> scene_state{nullptr};
        std::atomic<bool> scene_shutdown{false};

        struct provenance_context
        {
            std::uint64_t observation_id;
            DWORD observation_tid;
            const game::XModelSurfs* mesh;
            const game::XModelSurfs& copied_mesh;
            const std::string& copied_name;
            bool mesh_readable, model_default, lod_present;
        };

        unsigned long long address_value(const void* pointer)
        {
            return static_cast<unsigned long long>(reinterpret_cast<std::uintptr_t>(pointer));
        }

        void provenance(const provenance_context& context, const game::XSurface* pointer,
            const game::XSurface* copied_surface)
        {
            // Only inspect already-copied stack data and the already-read name.
            // No engine pointer is dereferenced here; these records do not pin allocations.
            const auto s = reinterpret_cast<std::uintptr_t>(pointer);
            const auto& mesh = context.copied_mesh;
            const char* refused = context.model_default ? "default_model" :
                !context.lod_present ? "lod_missing" :
                !context.mesh_readable || !context.mesh ? "mesh_unreadable" :
                context.copied_name != "paris_model_probe_lod0" ? "mesh_name_mismatch" :
                mesh.numsurfs != 1 ? "surface_count" :
                !s || pointer != mesh.surfs || s % alignof(game::XSurface) ||
                    s > std::numeric_limits<std::uintptr_t>::max() - sizeof(game::XSurface) ? "surface_relation" :
                !copied_surface ? "surface_unreadable" : nullptr;
            if (refused)
            {
                console::info("[Paris model provenance] observation_id=%llu observation_tid=%lu pid=%lu status=refused reason=%s H_invocation_verified=false allocation_identity_verified=false observation_tid_is_loader_tid=false atomic_snapshot_verified=false gpu_resource_verified=false\n",
                    static_cast<unsigned long long>(context.observation_id), context.observation_tid, GetCurrentProcessId(), refused);
                return;
            }
            const auto& data = *copied_surface;
            console::info("[Paris model provenance] observation_id=%llu observation_tid=%lu pid=%lu nonce=%s generation=%s status=sampled model=paris_model_probe mesh_name=paris_model_probe_lod0 mesh=0x%016llx mesh_name_address=0x%016llx base=0x%016llx count=%u index=0 S=0x%016llx P=0x%016llx flags=%u vertices=%u triangles=%u rigid=%u blend_size_18=%u verts_20=0x%016llx rigid_48=0x%016llx blend_50=0x%016llx buffer_58=0x%016llx view_60=0x%016llx table_relation_observed=true H_invocation_verified=false allocation_identity_verified=false observation_tid_is_loader_tid=false atomic_snapshot_verified=false gpu_resource_verified=false\n",
                static_cast<unsigned long long>(context.observation_id), context.observation_tid, GetCurrentProcessId(),
                observed_nonce.c_str(), observed_generation.c_str(), address_value(context.mesh), address_value(mesh.name),
                address_value(mesh.surfs), static_cast<unsigned int>(mesh.numsurfs), address_value(pointer),
                static_cast<unsigned long long>(s + offsetof(game::XSurface, blendVertsBuffer)),
                static_cast<unsigned int>(data.flags), static_cast<unsigned int>(data.vertCount),
                static_cast<unsigned int>(data.triCount), static_cast<unsigned int>(data.rigidVertListCount), data.blendVertSize,
                address_value(data.verts0.verts0), address_value(data.rigidVertLists), address_value(data.blendVerts),
                address_value(data.blendVertsBuffer), address_value(data.blendVertsView));
        }

        bool readable(const void* pointer, std::size_t bytes)
        {
            const auto address = reinterpret_cast<std::uintptr_t>(pointer);
            if (!address || !bytes || bytes > 4096 || address > std::numeric_limits<std::uintptr_t>::max() - bytes) return false;
            MEMORY_BASIC_INFORMATION region{};
            if (VirtualQuery(pointer, &region, sizeof(region)) != sizeof(region) || region.State != MEM_COMMIT ||
                (region.Protect & (PAGE_GUARD | PAGE_NOACCESS)) ||
                !(region.Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READ |
                    PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) return false;
            const auto base = reinterpret_cast<std::uintptr_t>(region.BaseAddress);
            return span_within(address, bytes, base, region.RegionSize);
        }
        // These leaf functions have no C++ objects requiring SEH unwinding.
        int memory_fault(unsigned code) noexcept
        {
            return code == EXCEPTION_ACCESS_VIOLATION || code == EXCEPTION_IN_PAGE_ERROR ?
                EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH;
        }
        bool copy_leaf(const void* pointer, void* value, std::size_t bytes) noexcept
        {
            __try { std::memcpy(value, pointer, bytes); return true; }
            __except(memory_fault(GetExceptionCode())) { return false; }
        }
        bool lookup_leaf(game::XAssetType type, const char* key, game::XAssetHeader* value) noexcept
        {
            __try { *value = game::DB_FindXAssetHeader(type, key, 0); return true; }
            __except(memory_fault(GetExceptionCode())) { return false; }
        }
        bool default_leaf(game::XAssetType type, const char* key, bool* value) noexcept
        {
            __try { *value = game::DB_IsXAssetDefault(type, key); return true; }
            __except(memory_fault(GetExceptionCode())) { return false; }
        }
        template <typename T> bool snapshot(const T* pointer, T& value)
        {
            if (!readable(pointer, sizeof(T))) return false;
            return copy_leaf(pointer, &value, sizeof(T));
        }
        std::string name(const char* pointer)
        {
            std::string text;
            for (std::size_t i = 0; i < 160; ++i)
            {
                if (!readable(pointer, 1)) return "unreadable";
                char c{};
                if (!copy_leaf(pointer++, &c, 1)) return "unreadable";
                if (!c) return text;
                if (static_cast<unsigned char>(c) < 32 || c == 127) return "invalid";
                text.push_back(c);
            }
            return "overlong";
        }
        bool exact_string_dvar(const char* key, const char* expected)
        {
            const auto* dvar = game::Dvar_FindVar(key);
            if (!dvar || dvar->type != game::DVAR_TYPE_STRING || !dvar->current.string) return false;
            // Allocation-free gate: no std::string construction can escape the
            // later optional diagnostic exception boundary.
            const auto length = std::strlen(expected);
            if (length >= 160 || !readable(dvar->current.string, length + 1)) return false;
            char copied[160]{};
            return copy_leaf(dvar->current.string, copied, length + 1) && std::memcmp(copied, expected, length + 1) == 0;
        }
        // -1 unreadable/null; 0 readable mismatch; 1 exact bounded match.
        int exact_name(const char* pointer, const char* expected)
        {
            const auto bytes = std::strlen(expected) + 1;
            char copied[128]{};
            if (bytes > sizeof(copied) || !readable(pointer, bytes) || !copy_leaf(pointer, copied, bytes)) return -1;
            return std::memcmp(copied, expected, bytes) == 0 ? 1 : 0;
        }
        default_status rig_default(game::XAssetType type, const char* key)
        {
            bool value{};
            const bool returned = default_leaf(type, key, &value);
            return observed_default(returned, value);
        }
        void rig_surface(const char* key, const char* path, const game::XSurface* pointer)
        {
            game::XSurface data{};
            if (!snapshot(pointer, data))
            {
                console::info("[Paris rig asset snapshot] model=%s path=%s readable=0\n", key, path);
                return;
            }
            console::info("[Paris rig asset snapshot] model=%s path=%s readable=1 raw_flags=%u vertices=%u triangles=%u rigid_lists=%u blend_size=%u cpu_vertices_present=%u cpu_indices_present=%u vb_present=%u vb_view_present=%u ib_present=%u ib_view_present=%u blend_buffer_present=%u blend_view_present=%u gpu_resource_verified=0 draw_verified=0\n",
                key, path, static_cast<unsigned>(data.flags), static_cast<unsigned>(data.vertCount), static_cast<unsigned>(data.triCount),
                static_cast<unsigned>(data.rigidVertListCount), data.blendVertSize, static_cast<unsigned>(data.verts0.verts0 != nullptr),
                static_cast<unsigned>(data.triIndices != nullptr), static_cast<unsigned>(data.vb0 != nullptr), static_cast<unsigned>(data.vb0View != nullptr),
                static_cast<unsigned>(data.indexBuffer != nullptr), static_cast<unsigned>(data.indexBufferView != nullptr),
                static_cast<unsigned>(data.blendVertsBuffer != nullptr), static_cast<unsigned>(data.blendVertsView != nullptr));
        }
        void rig_model(const char* key, const char* mesh_key, const game::Material* named_material)
        {
            constexpr auto material_key = "mopw/character_park_clown_zombie_shoes";
            const auto is_default = rig_default(game::ASSET_TYPE_XMODEL, key);
            game::XAssetHeader header{};
            const bool lookup_returned = lookup_leaf(game::ASSET_TYPE_XMODEL, key, &header);
            game::XModel data{};
            const bool copied = lookup_returned && snapshot(header.model, data);
            const int identity = copied ? exact_name(data.name, key) : -1;
            console::info("[Paris rig asset snapshot] model=%s lookup_returned=%u lookup_present=%d default_status=%d readable=%u name_match=%d\n",
                key, static_cast<unsigned>(lookup_returned), lookup_returned ? static_cast<int>(header.model != nullptr) : -1,
                static_cast<int>(is_default), static_cast<unsigned>(copied), identity);
            // Never follow a fallback or mismatched asset into foreign resources.
            if (!copied || identity != 1 || is_default == default_status::default_asset) return;
            const auto& lod = data.lodInfo[0];
            unsigned char has_lods{};
            std::memcpy(&has_lods, reinterpret_cast<const unsigned char*>(&data) + offsetof(game::XModel, hasLods), 1);
            console::info("[Paris rig asset snapshot] model=%s bones=%u root_bones=%u client_bones=%u surfaces=%u lods=%u has_lods_raw=%u max_loaded_lod=%u lod0_distance=%g lod0_surfaces=%u lod0_first=%u lod0_raw_flags=%u material_table_present=%u\n",
                key, static_cast<unsigned>(data.numBones), static_cast<unsigned>(data.numRootBones), static_cast<unsigned>(data.numClientBones),
                static_cast<unsigned>(data.numsurfs), static_cast<unsigned>(data.numLods), static_cast<unsigned>(has_lods), static_cast<unsigned>(data.maxLoadedLod),
                static_cast<double>(lod.dist), static_cast<unsigned>(lod.numsurfs), static_cast<unsigned>(lod.surfIndex),
                static_cast<unsigned>(static_cast<unsigned char>(lod.flags)), static_cast<unsigned>(data.materialHandles != nullptr));
            if (!lod0_span(data.numLods, data.numsurfs, lod.numsurfs, lod.surfIndex))
            {
                console::info("[Paris rig asset snapshot] model=%s status=refused reason=lod0_span\n", key);
                return;
            }
            game::XModelSurfs mesh{};
            const bool mesh_copied = snapshot(lod.modelSurfs, mesh);
            const int mesh_identity = mesh_copied ? exact_name(mesh.name, mesh_key) : -1;
            console::info("[Paris rig asset snapshot] model=%s mesh_readable=%u mesh_name_match=%d mesh_surfaces=%d resolved_surface_present=%u mesh_surface_present=%d same_nonnull_surface0=%d\n",
                key, static_cast<unsigned>(mesh_copied), mesh_identity, mesh_copied ? static_cast<int>(mesh.numsurfs) : -1,
                static_cast<unsigned>(lod.surfs != nullptr), mesh_copied ? static_cast<int>(mesh.surfs != nullptr) : -1,
                mesh_copied ? static_cast<int>(lod.surfs && lod.surfs == mesh.surfs) : -1);
            rig_surface(key, "resolved_lod0", lod.surfs);
            if (mesh_copied && mesh_identity == 1 && mesh.numsurfs > 0 && mesh.numsurfs <= 256)
                rig_surface(key, "mesh_surface0", mesh.surfs);
            game::Material* material{};
            game::Material value{};
            const bool handle_copied = snapshot(data.materialHandles, material);
            const bool material_copied = handle_copied && snapshot(material, value);
            console::info("[Paris rig asset snapshot] model=%s material0_handle_readable=%u material0_present=%d material0_readable=%u material0_name_match=%d material0_equals_named_lookup=%d technique_set_present=%d textures=%d\n",
                key, static_cast<unsigned>(handle_copied), handle_copied ? static_cast<int>(material != nullptr) : -1, static_cast<unsigned>(material_copied),
                material_copied ? exact_name(value.name, material_key) : -1, !named_material || !handle_copied ? -1 : static_cast<int>(material == named_material),
                material_copied ? static_cast<int>(value.techniqueSet != nullptr) : -1, material_copied ? static_cast<int>(value.textureCount) : -1);
        }
        void rig_assets(std::uint64_t observation_id)
        {
            constexpr auto key = "mopw/character_park_clown_zombie_shoes";
            const auto is_default = rig_default(game::ASSET_TYPE_MATERIAL, key);
            game::XAssetHeader header{};
            const bool returned = lookup_leaf(game::ASSET_TYPE_MATERIAL, key, &header);
            game::Material value{};
            const bool copied = returned && snapshot(header.material, value);
            const int identity = copied ? exact_name(value.name, key) : -1;
            console::info("[Paris rig asset snapshot] observation_id=%llu role=client stage=after_agent_arm tick_ms=%llu atomic_snapshot_verified=0 entity_dobj=unmeasured gpu_resource_verified=0 draw_verified=0\n",
                static_cast<unsigned long long>(observation_id), GetTickCount64());
            console::info("[Paris rig asset snapshot] material=%s lookup_returned=%u lookup_present=%d default_status=%d readable=%u name_match=%d technique_set_present=%d textures=%d\n",
                key, static_cast<unsigned>(returned), returned ? static_cast<int>(header.material != nullptr) : -1, static_cast<int>(is_default),
                static_cast<unsigned>(copied), identity, copied ? static_cast<int>(value.techniqueSet != nullptr) : -1, copied ? static_cast<int>(value.textureCount) : -1);
            const auto* named = copied && identity == 1 && is_default != default_status::default_asset ? header.material : nullptr;
            rig_model("paris_doom_skin_two_bone_first_a", "paris_doom_skin_two_bone_first_a_lod0", named);
            rig_model("paris_doom_skin_two_bone_second_a", "paris_doom_skin_two_bone_second_a_lod0", named);
        }
        bool scene_scope()
        {
            return !game::environment::is_dedi() && utils::flags::has_flag("paris-server-client-test") &&
                utils::flags::has_flag("paris-isolated-lab") && utils::flags::has_flag("paris-rig-assets-probe") &&
                utils::flags::has_flag("paris-rig-scene-probe") && exact_string_dvar("fs_game", "mods/sdk_original_rig_probe");
        }
        bool scene_protected(const paris_test_fixture::client_test_protection& value, std::uint64_t now)
        {
            return scene_scope() && paris_test_fixture::client_protection_current(value, now) && value.map == "cp_zmb" &&
                now >= value.query_tick && now - value.query_tick <= 250;
        }
        const char* scene_status_name(scene_status status)
        {
            switch (status)
            {
                case scene_status::sampled: return "sampled";
                case scene_status::cancelled: return "cancelled";
                case scene_status::expired: return "expired";
                case scene_status::count_refused: return "count_refused";
                case scene_status::read_fault: return "read_fault";
                case scene_status::budget_refused: return "budget_refused";
                default: return "no_scene_observation";
            }
        }
        // Called only from the existing MAIN observer/tick. The renderer never
        // calls an engine protection, DB, dvar or game-mode function.
        void maintain_scene(bool protected_now, std::uint64_t arm)
        {
            auto* state = scene_state.load(std::memory_order_acquire);
            if (!state) return;
            paris_test_fixture::client_test_protection current{};
            bool allowed{};
            if (protected_now)
            {
                current = paris_test_fixture::client_protection();
                allowed = scene_protected(current, GetTickCount64());
            }
            scene_result result{};
            std::uint64_t id{};
            bool publish{};
            bool stock_enabled{};
            std::uint64_t requested_tick{};
            {
                std::lock_guard lock(state->mutex);
                if (!state->pending) return;
                const auto now = GetTickCount64();
                allowed = allowed && arm && state->permit.arm == arm &&
                    scene_binding_matches(state->nonce, state->generation, state->challenge,
                        current.nonce, current.generation, current.challenge) && state->permit.pid == GetCurrentProcessId();
                if (!allowed || now >= state->permit.deadline)
                {
                    state->permit.cancelled = true;
                    state->result.status = now >= state->permit.deadline ? scene_status::expired : scene_status::cancelled;
                }
                else state->permit.validated_until = current.query_tick + 250;
                if (state->result.status == scene_status::pending) return;
                result = state->result; id = state->permit.request;
                stock_enabled = state->models[2] != 0; requested_tick = state->requested_tick;
                state->pending = false; state->permit.cancelled = true;
                publish = allowed && result.status == scene_status::sampled;
            }
            console::info("[Paris rig scene snapshot] observation_id=%llu role=client table=sceneModel phase=renderer_then_main status=%s observation=%s count_before=%d count_after=%d count_stable=%u matches_first=%d matches_second=%d stock_filter_enabled=%u matches_stock=%d records=%u truncated=%u atomic_snapshot_verified=0 entity_replication=unmeasured entity_dobj=unmeasured gpu_resource_verified=0 draw_verified=0\n",
                static_cast<unsigned long long>(id), scene_status_name(result.status), publish ? "SceneModelTableObserved" : "NoSceneObservation", result.before, result.after,
                static_cast<unsigned>(result.before >= 0 && result.before == result.after), publish ? static_cast<int>(result.matches[0]) : -1,
                publish ? static_cast<int>(result.matches[1]) : -1, static_cast<unsigned>(stock_enabled),
                publish && stock_enabled ? static_cast<int>(result.matches[2]) : -1, publish ? result.records : 0, static_cast<unsigned>(result.truncated));
            if (!publish) return;
            console::info("[Paris rig scene snapshot] observation_id=%llu requested_tick_ms=%llu sample_started_tick_ms=%llu sampled_tick_ms=%llu published_tick_ms=%llu absence_scope=not_observed_in_this_scene_model_table\n",
                static_cast<unsigned long long>(id), static_cast<unsigned long long>(requested_tick),
                static_cast<unsigned long long>(result.started_tick),
                static_cast<unsigned long long>(result.sampled_tick), GetTickCount64());
            for (unsigned i = 0; i < result.records; ++i)
            {
                const auto& row = result.rows[i];
                const auto* key = scene_keys[row.model];
                console::info("[Paris rig scene snapshot] observation_id=%llu model=%s model_role=%s record=%u scene_index=%d entnum_raw=%u obj_present=%u render_flags_raw=%u lod=%u material_lod=%u surface_bytes=%u surface_id=%u origin=(%g,%g,%g) quat=(%g,%g,%g,%g) scale=%g radius=%g server_entity_link=unmeasured dobj_models=unmeasured dobj_bones=unmeasured culling=unmeasured\n",
                    static_cast<unsigned long long>(id), key, row.model == 2 ? "stock_witness" : "custom_rig", i, row.index, row.entnum, static_cast<unsigned>(row.obj_present), row.render_flags, row.lod, row.material_lod,
                    row.surface_bytes, row.surface_id, static_cast<double>(row.origin[0]), static_cast<double>(row.origin[1]), static_cast<double>(row.origin[2]),
                    static_cast<double>(row.quat[0]), static_cast<double>(row.quat[1]), static_cast<double>(row.quat[2]), static_cast<double>(row.quat[3]),
                    static_cast<double>(row.scale), static_cast<double>(row.radius));
            }
        }
        void renderer_scene(scene_request* state, std::uint64_t id, std::uint64_t arm)
        {
            scene_result result{};
            std::array<std::uintptr_t, 3> models{};
            {
                std::lock_guard lock(state->mutex);
                models = state->models;
            }
            std::size_t budget = 16384;
            const auto copy = [&](const void* source, void* output, std::size_t bytes) -> bool
            {
                std::lock_guard lock(state->mutex);
                if (scene_shutdown.load(std::memory_order_acquire) || !state->pending ||
                    !scene_admitted(state->permit, id, arm, GetCurrentProcessId(), GetTickCount64()))
                {
                    result.status = state->permit.cancelled || state->permit.request != id ? scene_status::cancelled : scene_status::expired;
                    return false;
                }
                if (bytes > budget) { result.status = scene_status::budget_refused; return false; }
                budget -= bytes;
                if (!readable(source, bytes) || !copy_leaf(source, output, bytes)) { result.status = scene_status::read_fault; return false; }
                return true;
            };
            // The scene symbol/type and 1024 limit come from the pinned SDK.
            // No opaque sceneDObj entry or foreign model/DObj/resource is read.
            const auto* scene = game::scene.get();
            const auto* count = const_cast<const int*>(&scene->sceneModelCount);
            result.started_tick = GetTickCount64();
            if (copy(count, &result.before, sizeof(result.before)))
            {
                if (!scene_count_bounded(result.before)) result.status = scene_status::count_refused;
                else for (int i = 0; i < result.before && result.status == scene_status::pending; ++i)
                {
                    const game::XModel* model{};
                    if (!copy(&scene->sceneModel[i].model, &model, sizeof(model))) break;
                    const int selected = fixed_scene_model(reinterpret_cast<std::uintptr_t>(model), models[0], models[1], models[2]);
                    if (selected < 0) continue;
                    ++result.matches[static_cast<unsigned>(selected)];
                    if (result.records == result.rows.size()) { result.truncated = true; continue; }
                    game::GfxSceneModel entry{};
                    if (!copy(&scene->sceneModel[i], &entry, sizeof(entry))) break;
                    if (reinterpret_cast<std::uintptr_t>(entry.model) != models[static_cast<unsigned>(selected)])
                    { result.status = scene_status::read_fault; break; }
                    auto& row = result.rows[result.records++];
                    row.model = selected; row.index = i; row.entnum = entry.entnum; row.render_flags = entry.renderFlags;
                    row.obj_present = entry.obj != nullptr; row.lod = entry.info.lod; row.material_lod = entry.info.materialLod;
                    row.surface_bytes = entry.info.surfBufSize; row.surface_id = entry.info.surfId;
                    std::memcpy(row.origin, entry.placement.base.origin, sizeof(row.origin));
                    std::memcpy(row.quat, entry.placement.base.quat, sizeof(row.quat));
                    row.scale = entry.placement.scale; row.radius = entry.radius;
                }
                if (result.status == scene_status::pending && copy(count, &result.after, sizeof(result.after)))
                {
                    result.status = scene_count_bounded(result.after) ? scene_status::sampled : scene_status::count_refused;
                    result.sampled_tick = GetTickCount64();
                }
            }
            std::lock_guard lock(state->mutex);
            if (state->pending && state->permit.request == id && !state->permit.cancelled) state->result = result;
            // MAIN maintenance drains this POD result and revalidates before IO.
        }
        void request_scene(std::uint64_t id, std::uint64_t arm, const paris_test_fixture::client_test_protection& current)
        {
            if (scene_shutdown.load(std::memory_order_acquire) || !arm || !scene_protected(current, GetTickCount64())) return;
            auto* state = scene_state.load(std::memory_order_acquire);
            if (!state)
            {
                state = new scene_request;
                scene_state.store(state, std::memory_order_release);
            }
            {
                std::lock_guard lock(state->mutex);
                if (state->pending || (state->consumed_arm == arm && scene_binding_matches(state->nonce, state->generation,
                    state->challenge, current.nonce, current.generation, current.challenge))) return;
                state->consumed_arm = arm;
                state->nonce = current.nonce; state->generation = current.generation; state->challenge = current.challenge;
            }
            std::array<std::uintptr_t, 3> models{};
            const unsigned references = utils::flags::has_flag("paris-rig-scene-stock-witness") ? 3 : 2;
            for (unsigned i = 0; i < references; ++i)
            {
                game::XAssetHeader header{}; game::XModel model{};
                if (rig_default(game::ASSET_TYPE_XMODEL, scene_keys[i]) != default_status::nondefault ||
                    !lookup_leaf(game::ASSET_TYPE_XMODEL, scene_keys[i], &header) || !snapshot(header.model, model) || exact_name(model.name, scene_keys[i]) != 1)
                {
                    console::info("[Paris rig scene snapshot] observation_id=%llu table=sceneModel model=%s status=asset_reference_refused observation=NoSceneObservation\n", static_cast<unsigned long long>(id), scene_keys[i]);
                    return;
                }
                models[i] = reinterpret_cast<std::uintptr_t>(header.model);
            }
            if (fixed_scene_model(models[0], models[0], models[1], models[2]) != 0)
            {
                console::info("[Paris rig scene snapshot] observation_id=%llu table=sceneModel status=asset_reference_alias observation=NoSceneObservation\n", static_cast<unsigned long long>(id));
                return;
            }
            {
                std::lock_guard lock(state->mutex);
                if (state->pending) return;
                state->requested_tick = GetTickCount64();
                state->permit = {id, arm, state->requested_tick + 1000, current.query_tick + 250, GetCurrentProcessId(), false};
                state->models = models; state->result = {}; state->pending = true;
            }
            scheduler::once([state, id, arm]
            {
                try { renderer_scene(state, id, arm); }
                catch (const std::exception&)
                {
                    // A failed mutex operation must not unwind through the
                    // renderer hook. If it remains unavailable, MAIN expires.
                    try
                    {
                        std::lock_guard lock(state->mutex);
                        if (state->pending && state->permit.request == id && !state->permit.cancelled)
                            state->result.status = scene_status::read_fault;
                    }
                    catch (const std::exception&) {}
                }
            }, scheduler::renderer);
        }
        void surface(const char* label, const game::XSurface* pointer, const provenance_context* context = nullptr)
        {
            game::XSurface data{};
            if (!snapshot(pointer, data))
            {
                console::info("[Paris model diagnostic] surface=%s readable=0\n", label);
                if (context) provenance(*context, pointer, nullptr);
                return;
            }
            // Presence does not prove D3D resource validity or that any draw ran.
            console::info("[Paris model diagnostic] surface=%s readable=1 flags=%u vertices=%u triangles=%u rigid=%u cpu_vertices=%d cpu_indices=%d vb=%d vb_view=%d ib=%d ib_view=%d\n",
                label, data.flags, data.vertCount, data.triCount, data.rigidVertListCount,
                static_cast<int>(data.verts0.verts0 != nullptr), static_cast<int>(data.triIndices != nullptr),
                static_cast<int>(data.vb0 != nullptr), static_cast<int>(data.vb0View != nullptr),
                static_cast<int>(data.indexBuffer != nullptr), static_cast<int>(data.indexBufferView != nullptr));
            if (context) provenance(*context, pointer, &data);
        }
        void model(const char* key, std::uint64_t observation_id, DWORD observation_tid)
        {
            const bool is_default = game::DB_IsXAssetDefault(game::ASSET_TYPE_XMODEL, key);
            const auto header = game::DB_FindXAssetHeader(game::ASSET_TYPE_XMODEL, key, 0);
            game::XModel data{};
            if (!snapshot(header.model, data)) { console::info("[Paris model diagnostic] model=%s default=%d readable=0\n", key, static_cast<int>(is_default)); return; }
            console::info("[Paris model diagnostic] model=%s actual=%s default=%d readable=1 lods=%u max_loaded=%u has_lods=%d surfaces=%u flags=%d shadow=%u radius=%g\n",
                key, name(data.name).c_str(), static_cast<int>(is_default), data.numLods, data.maxLoadedLod,
                static_cast<int>(data.hasLods), data.numsurfs, data.flags, data.shadowCutoffLod, static_cast<double>(data.radius));
            if (data.numLods > 6 || data.numsurfs > 256) { console::info("[Paris model diagnostic] model=%s refused_counts=1\n", key); return; }
            // Only LOD0/surface0 are sampled for both fixed assets. No traversal
            // over a retail model's full mesh or COM object dereference.
            const auto& lod = data.lodInfo[0];
            game::XModelSurfs mesh{};
            const bool mesh_valid = snapshot(lod.modelSurfs, mesh);
            const auto mesh_name = mesh_valid ? name(mesh.name) : std::string("unreadable");
            console::info("[Paris model diagnostic] model=%s lod0_dist=%g lod0_surfaces=%u lod0_index=%u model_surfs_readable=%d model_surfs_name=%s model_surfs_count=%u resolved_surfs=%d\n",
                key, static_cast<double>(lod.dist), lod.numsurfs, lod.surfIndex, static_cast<int>(mesh_valid),
                mesh_name.c_str(), mesh_valid ? mesh.numsurfs : 0,
                static_cast<int>(lod.surfs != nullptr));
            if (data.numLods && lod.numsurfs) surface(key, lod.surfs);
            const bool selected = std::strcmp(key, "paris_model_probe") == 0;
            const provenance_context context{observation_id, observation_tid, lod.modelSurfs, mesh, mesh_name,
                mesh_valid, is_default, data.numLods != 0 && lod.numsurfs != 0};
            if (mesh_valid && mesh.numsurfs) surface("modelSurfs.surface0", mesh.surfs, selected ? &context : nullptr);
            else if (selected) provenance(context, nullptr, nullptr);
            game::Material* material{};
            if (data.numsurfs && snapshot(data.materialHandles, material))
            {
                game::Material value{};
                if (snapshot(material, value)) console::info("[Paris model diagnostic] model=%s material=%s technique_set=%d textures=%u\n",
                    key, name(value.name).c_str(), static_cast<int>(value.techniqueSet != nullptr), value.textureCount);
                else console::info("[Paris model diagnostic] model=%s material_readable=0\n", key);
            }
        }
        void fixed_assets(std::uint64_t observation_id, DWORD observation_tid)
        {
            model("paris_model_probe", observation_id, observation_tid); model("park_clown_zombie", observation_id, observation_tid);
            const auto mesh_header = game::DB_FindXAssetHeader(game::ASSET_TYPE_XMODEL_SURFS, "paris_model_probe_lod0", 0);
            game::XModelSurfs mesh{};
            const bool valid = snapshot(mesh_header.modelSurfs, mesh);
            console::info("[Paris model diagnostic] mesh=paris_model_probe_lod0 default=%d readable=%d count=%u\n",
                static_cast<int>(game::DB_IsXAssetDefault(game::ASSET_TYPE_XMODEL_SURFS, "paris_model_probe_lod0")), static_cast<int>(valid), valid ? mesh.numsurfs : 0);
            if (valid && mesh.numsurfs == 1) surface("fixedMesh.surface0", mesh.surfs);
            const auto strings_header = game::DB_FindXAssetHeader(game::ASSET_TYPE_NET_CONST_STRINGS, "ncs_mdl_paris_model_probe", 0);
            game::NetConstStrings strings{};
            const bool strings_valid = snapshot(strings_header.netConstStrings, strings);
            console::info("[Paris model diagnostic] ncs=ncs_mdl_paris_model_probe default=%d readable=%d type=%d source=%d count=%u\n",
                static_cast<int>(game::DB_IsXAssetDefault(game::ASSET_TYPE_NET_CONST_STRINGS, "ncs_mdl_paris_model_probe")),
                static_cast<int>(strings_valid), strings_valid ? static_cast<int>(strings.stringType) : -1,
                strings_valid ? static_cast<int>(strings.sourceType) : -1, strings_valid ? strings.entryCount : 0);
            const char* first{};
            if (strings_valid && strings.entryCount == 1 && snapshot(strings.stringList, first))
                console::info("[Paris model diagnostic] ncs_entry0=%s client_model_index=unmeasured entity_dobj=unmeasured gpu_draw=unmeasured\n", name(first).c_str());
        }
    }
    void observe_client(bool protected_now, std::uint64_t probe_tick, std::string_view client_nonce,
        std::string_view server_generation, std::string_view connection_challenge, bool capture_requested, std::uint64_t scene_arm)
    {
        if (!capture_requested)
        {
            // Teardown cancellation uses no engine API or logger, and is safe
            // even after main/renderer processing has stopped.
            if (!protected_now && !probe_tick && client_nonce.empty() && server_generation.empty() && connection_challenge.empty())
            {
                scene_shutdown.store(true, std::memory_order_release);
                if (auto* state = scene_state.load(std::memory_order_acquire))
                { std::lock_guard lock(state->mutex); state->permit.cancelled = true; state->pending = false; }
                return;
            }
            if (scene_shutdown.load(std::memory_order_acquire)) return;
            try { maintain_scene(protected_now, scene_arm); }
            catch (const std::exception&)
            {
                if (auto* state = scene_state.load(std::memory_order_acquire))
                { std::lock_guard lock(state->mutex); state->permit.cancelled = true; state->pending = false; }
            }
            return;
        }
        if (scene_shutdown.load(std::memory_order_acquire)) return;
        const auto now = GetTickCount64();
        if (game::environment::is_dedi() || !utils::flags::has_flag("paris-server-client-test") ||
            !utils::flags::has_flag("paris-isolated-lab") || !protected_now || !probe_tick || now < probe_tick || now - probe_tick > 500 ||
            !iw7::agent::nonce_valid(client_nonce) || !iw7::agent::nonce_valid(server_generation) || connection_challenge.empty() ||
            game::Com_GameMode_GetActiveGameMode() != game::GAME_MODE_CP || !game::CL_IsGameClientActive(0) ||
            !game::clientUIActives[0].cgameInitialized || game::clientUIActives[0].connectionState != game::CA_ACTIVE) return;
        try
        {
            const bool model_scope = exact_string_dvar("fs_game", "mods/paris_model_probe");
            const bool rig_scope = exact_string_dvar("fs_game", "mods/sdk_original_rig_probe");
            const auto selected = select_profile(model_scope ? "mods/paris_model_probe" : rig_scope ? "mods/sdk_original_rig_probe" : "",
                rig_scope && utils::flags::has_flag("paris-rig-assets-probe"));
            if (selected == profile::none) return;
            if (selected == profile::original_rig)
            {
                const auto protection = paris_test_fixture::client_protection();
                if (!paris_test_fixture::client_protection_current(protection, GetTickCount64()) || protection.map != "cp_zmb" ||
                    protection.nonce != client_nonce || protection.generation != server_generation || protection.challenge != connection_challenge) return;
                if (scene_arm)
                {
                    maintain_scene(protected_now, scene_arm);
                    if (observation_sequence != std::numeric_limits<std::uint64_t>::max())
                        request_scene(++observation_sequence, scene_arm, protection);
                    return;
                }
            }
            if (observed_profile == selected && observed_nonce == client_nonce && observed_generation == server_generation && observed_challenge == connection_challenge) return;
            observed_nonce = client_nonce; observed_generation = server_generation; observed_challenge = connection_challenge;
            observed_profile = selected;
            if (observation_sequence == std::numeric_limits<std::uint64_t>::max())
            {
                console::error("[Paris model provenance] status=refused reason=observation_id_exhausted H_invocation_verified=false allocation_identity_verified=false observation_tid_is_loader_tid=false atomic_snapshot_verified=false gpu_resource_verified=false\n");
                return;
            }
            const auto observation_id = ++observation_sequence;
            if (selected == profile::original_rig)
            {
                rig_assets(observation_id);
                return;
            }
            const auto observation_tid = GetCurrentThreadId();
            console::info("[Paris model diagnostic] pid=%lu nonce=%s generation=%s tick_ms=%llu protected=1 once_per_connection=1\n",
                GetCurrentProcessId(), observed_nonce.c_str(), observed_generation.c_str(), now);
            fixed_assets(observation_id, observation_tid);
        }
        catch (const std::exception&)
        {
            // An optional observer must not unwind through the engine scheduler.
            console::error("[Paris model diagnostic] snapshot_exception=1 evidence_complete=0\n");
        }
    }
}
