#include <std_include.hpp>
#include "paris_model_diagnostics.hpp"
#include "agent_scenario.hpp"
#include "paris_test_safety.hpp"
#include "game/game.hpp"
#include "console/console.hpp"
#include <utils/flags.hpp>
#include <cstring>
#include <limits>

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
        std::string observed_nonce, observed_generation, observed_challenge;
        profile observed_profile = profile::none;
        std::uint64_t observation_sequence{}; // Main-thread observation ID, not a loader invocation.

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
            console::info("[Paris rig asset snapshot] model=%s lookup_returned=%u lookup_present=%u default_status=%d readable=%u name_match=%d\n",
                key, static_cast<unsigned>(lookup_returned), static_cast<unsigned>(lookup_returned && header.model != nullptr),
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
            console::info("[Paris rig asset snapshot] model=%s mesh_readable=%u mesh_name_match=%d mesh_surfaces=%u resolved_surface_present=%u mesh_surface_present=%u same_surface0=%u\n",
                key, static_cast<unsigned>(mesh_copied), mesh_identity, mesh_copied ? static_cast<unsigned>(mesh.numsurfs) : 0,
                static_cast<unsigned>(lod.surfs != nullptr), static_cast<unsigned>(mesh_copied && mesh.surfs != nullptr),
                static_cast<unsigned>(mesh_copied && lod.surfs && lod.surfs == mesh.surfs));
            rig_surface(key, "resolved_lod0", lod.surfs);
            if (mesh_copied && mesh_identity == 1 && mesh.numsurfs > 0 && mesh.numsurfs <= 256)
                rig_surface(key, "mesh_surface0", mesh.surfs);
            game::Material* material{};
            game::Material value{};
            const bool handle_copied = snapshot(data.materialHandles, material);
            const bool material_copied = handle_copied && snapshot(material, value);
            console::info("[Paris rig asset snapshot] model=%s material0_handle_readable=%u material0_present=%u material0_readable=%u material0_name_match=%d material0_equals_named_lookup=%d technique_set_present=%u textures=%u\n",
                key, static_cast<unsigned>(handle_copied), static_cast<unsigned>(handle_copied && material != nullptr), static_cast<unsigned>(material_copied),
                material_copied ? exact_name(value.name, material_key) : -1, !named_material || !handle_copied ? -1 : static_cast<int>(material == named_material),
                static_cast<unsigned>(material_copied && value.techniqueSet != nullptr), material_copied ? static_cast<unsigned>(value.textureCount) : 0);
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
            console::info("[Paris rig asset snapshot] material=%s lookup_returned=%u lookup_present=%u default_status=%d readable=%u name_match=%d technique_set_present=%u textures=%u\n",
                key, static_cast<unsigned>(returned), static_cast<unsigned>(returned && header.material != nullptr), static_cast<int>(is_default),
                static_cast<unsigned>(copied), identity, static_cast<unsigned>(copied && value.techniqueSet != nullptr), copied ? static_cast<unsigned>(value.textureCount) : 0);
            const auto* named = copied && identity == 1 && is_default != default_status::default_asset ? header.material : nullptr;
            rig_model("paris_doom_skin_two_bone_first_a", "paris_doom_skin_two_bone_first_a_lod0", named);
            rig_model("paris_doom_skin_two_bone_second_a", "paris_doom_skin_two_bone_second_a_lod0", named);
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
        std::string_view server_generation, std::string_view connection_challenge)
    {
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
            if (selected == profile::original_rig) { rig_assets(observation_id); return; }
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
