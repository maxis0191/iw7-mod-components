#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "console/console.hpp"
#include "paris_usermap_base.hpp"
#include <utils/hook.hpp>
#include <cstdint>
#include <cstring>
#include <set>
#include <utility>
#include <vector>
#include <string>

// F8: the hint table of a reference build (docs/USERMAP-BASE.md). The engine adds the strings of EVERY loaded netconststrings asset to the per-kind tables
// (FUN_1406D52B0, called from the level's NCS pass FUN_1406D43C0), and the hint table holds 254 slots. A usermap whose `.base` loads cp_zmb gets the base's
// language copies of the hint list (ncs_hnt_eng_cp_zmb 235 strings, ncs_hnt_eng_patch_cp_zmb 9): 252 slots taken before any script runs, so the first new hint
// string of the map ends the level ("Can't precache more assets of type 'hint string'"). This component keeps those two assets out of the table while a usermap
// with a base is loaded. A hint that the stock scripts set still gets its slot at its first use (FUN_1405E9D90), nothing is lost but the pre-registration.
//
// Server and client both run the NCS pass and both sum the same list (the sum is hashed into DAT_145206474 and checked between them), so the switch must be the
// same on both sides: dvar paris_usermap_hint_filter, default 1; 0 gives the stock behaviour. Studio's A/B: `+set paris_usermap_hint_filter 0` on both.
namespace paris_usermap_ncs
{
    namespace
    {
        constexpr std::uintptr_t register_function = 0x1406D52B0ull;
        utils::hook::detour register_hook;
        std::set<std::string> logged;

        bool filter_enabled()
        {
            const auto* setting = game::Dvar_FindVar("paris_usermap_hint_filter");
            return !setting || setting->type != game::DVAR_TYPE_INT || setting->current.integer != 0;
        }

        // The usermap whose .base was read last is the map being loaded, and the base zones are in the engine's zone table: a stock map loaded later in the
        // same process (cp_zmb itself) is not that usermap and keeps every list.
        bool filter_active()
        {
            const auto& map = paris_usermap_base::current_usermap();
            return !map.empty() && !paris_usermap_base::current_bases().empty() && paris_usermap_base::zone_loaded(map.data()) && filter_enabled();
        }

        // F9: content wins (docs/USERMAP-BASE.md). The link step keeps the asset of the zone linked first and throws the later one away (FUN_140A77D20, one caller:
        // FUN_140A782B0). With a base zone loaded first the map's own copy of a data table that the engine or the stock scripts read BY NAME (a string table such as
        // cp/zombies/zombie_perks_bit_mask_table.csv, a raw file such as a vision, a netconststrings list such as ncs_efx_level) is lost. For those types, when the loading
        // zone is the usermap's own and the name is held by another zone, the header contents of the map's asset are copied over the entry's header (every pointer to the
        // name sees the map's content) and the base's header bytes are kept; before the engine frees the map's zone (FUN_140A76280) they are put back, so a resident base
        // and a stock map loaded later see their own content again.
        constexpr std::uintptr_t drop_function = 0x140A77D20ull;
        constexpr std::uintptr_t free_function = 0x140A76280ull;
        constexpr std::uintptr_t asset_table = 0x1453E7370ull;
        constexpr std::uintptr_t loading_zone_index = 0x143A7A7D4ull;
        constexpr std::uintptr_t type_size_function = 0x1409E5BD0ull;
        utils::hook::detour drop_hook;
        utils::hook::detour free_hook;

        struct swapped_asset
        {
            int type{};
            std::string name;
            void* header{};
            std::vector<std::uint8_t> base_bytes;
        };

        std::vector<swapped_asset> swapped;

        bool swap_enabled()
        {
            const auto* setting = game::Dvar_FindVar("paris_usermap_map_wins");
            return !setting || setting->type != game::DVAR_TYPE_INT || setting->current.integer != 0;
        }

        // only what the map's `.base` lists with `!<type> <name>` (the build's own record of what it edited under a stock name)
        bool listed(int type, const char* name)
        {
            for (const auto& item : paris_usermap_base::current_wins())
            {
                if (item.type == type && item.name == name)
                {
                    return true;
                }
            }

            return false;
        }

        const char* entry_zone(const void* entry)
        {
            const auto slot = *reinterpret_cast<const std::uint16_t*>(reinterpret_cast<const std::uint8_t*>(entry) + 0x12);
            return slot == 0 ? nullptr : game::DB_Zones_GetZoneNameFromIndex(slot);
        }

        void drop_stub(void* thrown, void* existing, unsigned type)
        {
            if (thrown != nullptr && existing != nullptr && thrown != existing && usermap_base::is_data_table_type(static_cast<int>(type)) && swap_enabled()
                && !paris_usermap_base::current_usermap().empty() && !paris_usermap_base::current_wins().empty())
            {
                const auto* loading = game::DB_Zones_GetZoneNameFromIndex(*reinterpret_cast<const int*>(loading_zone_index));
                game::XAssetHeader header{};
                header.data = existing;
                const auto* name = game::DB_GetXAssetHeaderName(static_cast<game::XAssetType>(type), header);
                if (usermap_base::is_map_own_zone(loading, paris_usermap_base::current_usermap()) && name != nullptr && listed(static_cast<int>(type), name))
                {
                    const auto* entry = game::DB_AssetEntryTable_FindAsset(reinterpret_cast<void*>(asset_table), name, static_cast<game::XAssetType>(type));
                    const auto* holder = entry != nullptr ? entry_zone(entry) : nullptr;
                    const auto size = reinterpret_cast<int (*)(int)>(type_size_function)(static_cast<int>(type));
                    if (holder != nullptr && !usermap_base::is_map_own_zone(holder, paris_usermap_base::current_usermap()) && size > 0 && size <= 256)
                    {
                        auto known = false;
                        for (const auto& item : swapped)
                        {
                            known = known || (item.type == static_cast<int>(type) && item.name == name);
                        }

                        if (!known)
                        {
                            swapped_asset item;
                            item.type = static_cast<int>(type);
                            item.name = name;
                            item.header = existing;
                            item.base_bytes.assign(static_cast<const std::uint8_t*>(existing), static_cast<const std::uint8_t*>(existing) + size);
                            swapped.push_back(std::move(item));
                        }

                        std::memcpy(existing, thrown, static_cast<std::size_t>(size));
                        console::info("[usermap map wins] %s %s: the content of zone %s replaces the one of zone %s (put back when %s unloads)\n", game::g_assetNames[type], name,
                            loading, holder, loading);
                    }
                }
            }

            drop_hook.invoke<void>(thrown, existing, type);
        }

        // The zone free: `list` = {pointer to the u16 zone slots, count}. When a slot of the usermap's own zones is on it, every swapped header goes back (only when the entry
        // still exists and still holds the header that was changed).
        void free_stub(void* table, void* mask, void* list)
        {
            if (!swapped.empty() && list != nullptr)
            {
                const auto* slots = *reinterpret_cast<const std::uint16_t* const*>(list);
                const auto count = *reinterpret_cast<const std::uint32_t*>(reinterpret_cast<const std::uint8_t*>(list) + 8);
                auto map_goes = false;
                for (std::uint32_t i = 0; slots != nullptr && i < count && i < 512; ++i)
                {
                    map_goes = map_goes || usermap_base::is_map_own_zone(game::DB_Zones_GetZoneNameFromIndex(slots[i]), paris_usermap_base::current_usermap());
                }

                if (map_goes)
                {
                    unsigned back = 0;
                    for (const auto& item : swapped)
                    {
                        const auto* entry = game::DB_AssetEntryTable_FindAsset(reinterpret_cast<void*>(asset_table), item.name.data(), static_cast<game::XAssetType>(item.type));
                        if (entry != nullptr && *reinterpret_cast<void* const*>(entry) == item.header)
                        {
                            std::memcpy(item.header, item.base_bytes.data(), item.base_bytes.size());
                            ++back;
                        }
                    }

                    console::info("[usermap map wins] %u of %u swapped assets put back before the zone is freed\n", back, static_cast<unsigned>(swapped.size()));
                    swapped.clear();
                }
            }

            free_hook.invoke<void>(table, mask, list);
        }

        std::uint64_t register_stub(void* asset)
        {
            if (asset != nullptr && filter_active())
            {
                const auto* name = *reinterpret_cast<const char* const*>(asset);
                if (usermap_base::is_base_hint_list(name, paris_usermap_base::current_bases()))
                {
                    if (logged.insert(name).second)
                    {
                        console::info("[usermap ncs] hint list %s of the base zone is not registered (usermap %s, dvar paris_usermap_hint_filter)\n", name,
                            paris_usermap_base::current_usermap().data());
                    }

                    return 1;
                }
            }

            return register_hook.invoke<std::uint64_t>(asset);
        }
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            game::Dvar_RegisterInt("paris_usermap_hint_filter", 1, 0, 1, game::DVAR_FLAG_NONE, "Usermap with a base zone: keep the base's own hint string lists out of the 254 hint slots");
            game::Dvar_RegisterInt("paris_usermap_map_wins", 1, 0, 1, game::DVAR_FLAG_NONE, "Usermap with a base zone: the base zones load as plain zones (not the base map: the level's world is the map's) and the map's listed data tables win (0 = the old behaviour)");
            register_hook.create(register_function, register_stub); // queued: main applies every queued hook after post_unpack
            drop_hook.create(drop_function, drop_stub);
            free_hook.create(free_function, free_stub);
        }
    };
}

REGISTER_COMPONENT(paris_usermap_ncs::component)
