#pragma once

#include <deque>
#include <functional>

#include <std_include.hpp>

#include "console/console.hpp"
#include "fastfiles.hpp"

#include <utils/io.hpp>
#include <utils/string.hpp>

#include "usermap_base_policy.hpp"

// Reference build for usermaps (studio gate G1): usermaps/<map>/<map>.base lists stock zones that are loaded right before
// the map's own zone, so the map's fastfile can carry only its own assets and refer to the rest by name. No file, no effect;
// a zone that is not found is logged and skipped. Server and client alike, because it sits on the zone load itself.
// Called from the zone load stub of fastfiles.cpp (an edit in ops/frame-cuts/frame-cut-edits.json).
namespace paris_usermap_base
{
	inline void load_before(const char* zone_name, const std::function<void(const char*)>& load)
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
			return;
		}

		std::vector<std::string> rejected;
		const auto zones = usermap_base::parse_base_list(text, &rejected);
		for (const auto& name : rejected)
		{
			console::error("Base zone name '%s' for usermap %s is not a zone name, skipped\n", name.data(), zone_name);
		}

		// the engine may keep the name pointer after the call
		static std::deque<std::string> names;
		for (const auto& zone : zones)
		{
			if (!fastfiles::exists(zone, true))
			{
				console::error("Base zone %s for usermap %s not found, skipped\n", zone.data(), zone_name);
				continue;
			}

			names.push_back(zone);
			console::info("Loading base zone %s for usermap %s\n", zone.data(), zone_name);
			load(names.back().data());
		}
	}
}
