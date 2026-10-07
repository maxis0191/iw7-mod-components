#include <std_include.hpp>
#include "paris_model_diagnostics.hpp"
#include "agent_scenario.hpp"
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
        static_assert(sizeof(game::XSurface) == 0x100);
        static_assert(offsetof(game::XSurface, verts0) == 0x20);
        static_assert(offsetof(game::XSurface, vb0) == 0x30);
        static_assert(sizeof(game::NetConstStrings) == 0x20);
        static_assert(offsetof(game::NetConstStrings, stringList) == 0x18);
        static_assert(offsetof(game::Material, techniqueSet) == 0x38);
        std::string observed_nonce, observed_generation, observed_challenge;

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
        template <typename T> bool snapshot(const T* pointer, T& value)
        {
            if (!readable(pointer, sizeof(T))) return false;
            std::memcpy(&value, pointer, sizeof(T)); return true;
        }
        std::string name(const char* pointer)
        {
            std::string text;
            for (std::size_t i = 0; i < 160; ++i)
            {
                if (!readable(pointer, 1)) return "unreadable";
                const char c = *pointer++;
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
            return std::memcmp(dvar->current.string, expected, length + 1) == 0;
        }
        void surface(const char* label, const game::XSurface* pointer)
        {
            game::XSurface data{};
            if (!snapshot(pointer, data)) { console::info("[Paris model diagnostic] surface=%s readable=0\n", label); return; }
            // Presence does not prove D3D resource validity or that any draw ran.
            console::info("[Paris model diagnostic] surface=%s readable=1 flags=%u vertices=%u triangles=%u rigid=%u cpu_vertices=%d cpu_indices=%d vb=%d vb_view=%d ib=%d ib_view=%d\n",
                label, data.flags, data.vertCount, data.triCount, data.rigidVertListCount,
                static_cast<int>(data.verts0.verts0 != nullptr), static_cast<int>(data.triIndices != nullptr),
                static_cast<int>(data.vb0 != nullptr), static_cast<int>(data.vb0View != nullptr),
                static_cast<int>(data.indexBuffer != nullptr), static_cast<int>(data.indexBufferView != nullptr));
        }
        void model(const char* key)
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
            console::info("[Paris model diagnostic] model=%s lod0_dist=%g lod0_surfaces=%u lod0_index=%u model_surfs_readable=%d model_surfs_name=%s model_surfs_count=%u resolved_surfs=%d\n",
                key, static_cast<double>(lod.dist), lod.numsurfs, lod.surfIndex, static_cast<int>(mesh_valid),
                mesh_valid ? name(mesh.name).c_str() : "unreadable", mesh_valid ? mesh.numsurfs : 0,
                static_cast<int>(lod.surfs != nullptr));
            if (data.numLods && lod.numsurfs) surface(key, lod.surfs);
            if (mesh_valid && mesh.numsurfs) surface("modelSurfs.surface0", mesh.surfs);
            game::Material* material{};
            if (data.numsurfs && snapshot(data.materialHandles, material))
            {
                game::Material value{};
                if (snapshot(material, value)) console::info("[Paris model diagnostic] model=%s material=%s technique_set=%d textures=%u\n",
                    key, name(value.name).c_str(), static_cast<int>(value.techniqueSet != nullptr), value.textureCount);
                else console::info("[Paris model diagnostic] model=%s material_readable=0\n", key);
            }
        }
        void fixed_assets()
        {
            model("paris_model_probe"); model("park_clown_zombie");
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
            !exact_string_dvar("fs_game", "mods/paris_model_probe") ||
            game::Com_GameMode_GetActiveGameMode() != game::GAME_MODE_CP || !game::CL_IsGameClientActive(0) ||
            !game::clientUIActives[0].cgameInitialized || game::clientUIActives[0].connectionState != game::CA_ACTIVE) return;
        if (observed_nonce == client_nonce && observed_generation == server_generation && observed_challenge == connection_challenge) return;
        try
        {
            observed_nonce = client_nonce; observed_generation = server_generation; observed_challenge = connection_challenge;
            console::info("[Paris model diagnostic] pid=%lu nonce=%s generation=%s tick_ms=%llu protected=1 once_per_connection=1\n",
                GetCurrentProcessId(), observed_nonce.c_str(), observed_generation.c_str(), now);
            fixed_assets();
        }
        catch (const std::exception&)
        {
            // An optional observer must not unwind through the engine scheduler.
            console::error("[Paris model diagnostic] snapshot_exception=1 evidence_complete=0\n");
        }
    }
}
