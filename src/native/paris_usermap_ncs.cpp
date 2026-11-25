#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "console/console.hpp"
#include "paris_usermap_base.hpp"
#include <utils/hook.hpp>
#include <cstdint>
#include <set>
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
            register_hook.create(register_function, register_stub); // queued: main applies every queued hook after post_unpack
        }
    };
}

REGISTER_COMPONENT(paris_usermap_ncs::component)
