#pragma once

#include <deque>
#include <functional>
#include <string>
#include <vector>

#include <std_include.hpp>

#include "console/console.hpp"
#include "fastfiles.hpp"
#include "game/game.hpp"

#include <utils/io.hpp>
#include <utils/string.hpp>

#include "usermap_base_policy.hpp"

// Reference build for usermaps (studio gate G1): usermaps/<map>/<map>.base lists stock zones that are loaded right before
// the map's own zone, so the map's fastfile can carry only its own assets and refer to the rest by name. No file, no effect;
// a zone that is not found is logged and skipped; `<zone> nopatch` loads the zone without the engine's patch_<zone>, `<zone> resident` loads it once per game process (see load_before). Server and client alike, because it sits on the zone load itself.
// Called from the zone load stub of fastfiles.cpp (an edit in ops/frame-cuts/frame-cut-edits.json).
namespace paris_usermap_base
{
	// The usermap whose `.base` list was read last and the zones on it (F8: paris_usermap_ncs.cpp filters the base's hint lists only while that map is loaded).
	inline std::string& current_usermap()
	{
		static std::string name;
		return name;
	}

	inline std::vector<std::string>& current_bases()
	{
		static std::vector<std::string> names;
		return names;
	}

	// Is a zone of this name in the engine's zone table right now? The table is the engine's own truth (373 slots at 0x143A124F8, 0x478 bytes each, the name first): a
	// resident zone that the engine freed (a mode switch unloads permanent zones too) is loaded again, one it still holds is not.
	inline bool zone_loaded(const char* name)
	{
		for (int slot = 1; slot < usermap_base::zone_slots; ++slot)
		{
			if (game::DB_Zones_IsValidZoneIndex(slot) && usermap_base::same_zone_name(game::DB_Zones_GetZoneNameFromIndex(slot), name))
			{
				return true;
			}
		}

		return false;
	}

	// `load(zone, mode)`: loads one zone before the map's. `mode.custom` = load it with the engine's DB_ZONE_CUSTOM flag, which makes the engine's load
	// function skip every extra zone it would add (techsets_, cache_, patch_ and the language ones, see skip_extra_zones_stub in fastfiles.cpp, which clears
	// the flag again and queues only the zone itself). A `nopatch` line does that and queues the two extras the zone needs by hand, in the engine's order.
	// `mode.permanent` = load the zone with the engine's DB_ZONE_PERMANENT flag alone (no level bit): the level's unload does not free it, so a reload of the map in the
	// same process does not need it again (a `resident` line; the loader then skips the zone while the engine's zone table holds it, `zone_loaded`).
	inline void load_before(const char* zone_name, const std::function<void(const char*, const usermap_base::load_mode&)>& load)
	{
		// The list file itself is the switch: a dedicated server started with +map never sets the current usermap
		// (measured 22 Nov 2026: the zone loaded, the list was not read), so the party state is not asked.
		if (zone_name == nullptr || !usermap_base::valid_zone_name(zone_name))
		{
			return;
		}

		std::string text;
		if (!utils::io::read_file(utils::string::va("usermaps/%s/%s.base", zone_name, zone_name), &text))
		{
			if (current_usermap() == zone_name)
			{
				current_usermap().clear();
				current_bases().clear();
			}

			return;
		}

		std::vector<std::string> rejected;
		const auto zones = usermap_base::parse_base_entries(text, &rejected);
		for (const auto& name : rejected)
		{
			console::error("Base zone line '%s' for usermap %s is not a zone name (with the option nopatch), skipped\n", name.data(), zone_name);
		}

		current_usermap() = zone_name;
		current_bases().clear();
		for (const auto& zone : zones)
		{
			current_bases().push_back(zone.name);
		}

		// the engine may keep the name pointer after the call
		static std::deque<std::string> names;
		for (const auto& zone : zones)
		{
			if (!fastfiles::exists(zone.name, true))
			{
				console::error("Base zone %s for usermap %s not found, skipped\n", zone.name.data(), zone_name);
				continue;
			}

			// A resident zone is loaded once per game process: the second load of the same map (a reload in place) finds it in the engine's zone table and skips it.
			if (zone.resident && zone_loaded(zone.name.data()))
			{
				console::info("Base zone %s for usermap %s is resident, not loaded again\n", zone.name.data(), zone_name);
				continue;
			}

			usermap_base::load_mode mode;
			mode.custom = zone.no_patch;
			mode.permanent = zone.resident;

			if (zone.no_patch)
			{
				usermap_base::load_mode companion_mode;
				companion_mode.permanent = zone.resident;
				for (const auto& companion : usermap_base::companion_zones(zone.name))
				{
					if (fastfiles::exists(companion, true))
					{
						names.push_back(companion);
						console::info("Loading base companion zone %s for usermap %s\n", companion.data(), zone_name);
						load(names.back().data(), companion_mode);
					}
				}
			}

			names.push_back(zone.name);
			console::info("Loading base zone %s for usermap %s%s%s\n", zone.name.data(), zone_name, zone.no_patch ? " (custom flag: no patch_ zone)" : "", zone.resident ? " (resident)" : "");
			load(names.back().data(), mode);
		}
	}
}
