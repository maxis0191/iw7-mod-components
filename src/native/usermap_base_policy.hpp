#pragma once

#include <cstring>
#include <string>
#include <vector>

// Which stock zones a usermap loads right before its own zone (the reference build, studio gate G1).
// usermaps/<map>/<map>.base holds one zone name per line; a line that starts with // is a comment.
// Pure text rules, no engine calls, so they can be tested without the game (tests/native/usermap_base_test.cpp).
namespace usermap_base
{
	// A zone name is a bare file name stem: no folder part, no extension, nothing that leaves usermaps/ or zone/.
	inline bool valid_zone_name(const std::string& name)
	{
		if (name.empty() || name.size() > 63)
		{
			return false;
		}

		for (const auto c : name)
		{
			const auto ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
			if (!ok)
			{
				return false;
			}
		}

		return true;
	}

	// One line of the list: a zone name and, after blanks, up to two options in any order:
	//  `nopatch`  the engine's own extra zones of that zone are not loaded: no patch_<zone> whose assets would win over the map's own copies; the loader adds the ones
	//             the zone needs, techsets_<zone> and cache_<zone>, by name.
	//  `resident` the zone (and the companions the loader adds for it) is loaded once per game process with the engine's permanent flag and is not loaded again when
	//             the map is loaded again in the same process (a reload in place: Studio's live loop). Without it every map load loads the zone again.
	struct entry
	{
		std::string name;
		bool no_patch = false;
		bool resident = false;
	};

	// The engine's zone flag for a zone that no level unload frees (DB_ZONE_PERMANENT in game/types/database.hpp; the same flag `loadzone` and the code zones use).
	constexpr int zone_flag_permanent = 0x1;

	// How the loader asks the engine to load one zone before the map's.
	struct load_mode
	{
		bool custom = false;     // DB_ZONE_CUSTOM: the engine adds none of the extra zones of this one
		bool permanent = false;  // DB_ZONE_PERMANENT: the zone stays loaded when the level is left
	};

	// The flags of one base zone load. A level zone carries the level's own flags (`zone_flags`, DB_ZONE_GAME = 0x80 for a map), which are what the level's unload
	// frees. A resident zone belongs to the process, not to the level: it carries the permanent flag ALONE (the way `loadzone` and the code zones load), so no level
	// bit is left for an unload to match. `custom_flag` is DB_ZONE_CUSTOM, added when the mode asks for it.
	inline unsigned int load_flags(unsigned int zone_flags, const load_mode& mode, unsigned int custom_flag)
	{
		const unsigned int own = mode.permanent ? static_cast<unsigned int>(zone_flag_permanent) : zone_flags;
		return own | (mode.custom ? custom_flag : 0u);
	}

	// The engine's zone table has 373 slots (0 is "<default>"); a slot with a name is a zone in memory. The engine's own unload loop walks slots 1..372 (0x140A7B7D0).
	constexpr int zone_slots = 0x175;

	// Two zone names are the same zone when they agree ignoring ASCII case (the engine compares names that way).
	inline bool same_zone_name(const char* a, const char* b)
	{
		if (a == nullptr || b == nullptr)
		{
			return false;
		}

		while (*a != '\0' && *b != '\0')
		{
			const auto lower = [](const char c) { return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c; };
			if (lower(*a) != lower(*b))
			{
				return false;
			}

			++a;
			++b;
		}

		return *a == *b;
	}

	// F9 (docs/USERMAP-BASE.md, "map assets win"): the zone linked first wins a name, so with `paris_usermap_map_wins` the base zones of a usermap are queued AFTER the map's own
	// zones (the engine's zone load queues techsets_<map>, patch_<map> and the map itself). A resident (permanent) base would then keep pointers into the map's headers after
	// the map is freed, so under map-wins a base is loaded as an ordinary level zone: it is freed with the map and the stock map finds its own assets again.
	enum class base_phase
	{
		before,
		after
	};

	// Does the base load in this phase? Old order (`wins` false): before the map. Map-wins order: after it.
	inline bool loads_in_phase(bool wins, base_phase phase)
	{
		return wins == (phase == base_phase::after);
	}

	inline load_mode map_wins_mode(load_mode mode)
	{
		mode.permanent = false;
		return mode;
	}

	// Is the zone one of the usermap's own (its level zone or its patch zone)?
	inline bool is_map_own_zone(const char* zone, const std::string& usermap)
	{
		if (zone == nullptr || usermap.empty())
		{
			return false;
		}

		return same_zone_name(zone, usermap.data()) || same_zone_name(zone, ("patch_" + usermap).data());
	}

	// F8 (docs/USERMAP-BASE.md, "the hint table of a reference build"): the engine registers EVERY loaded netconststrings asset, and the base zone brings its own
	// language copies of the hint list (`ncs_hnt_<lang>_<base>` and `ncs_hnt_<lang>_patch_<base>`: 244 of the 254 hint slots for cp_zmb). Is this asset one of them?
	// Only the hint kind (`hnt`): it is the one list that is capacity bound (255 slots, 252 used by the base; every other kind is far below its table, measured).
	inline bool is_base_hint_list(const char* asset_name, const std::vector<std::string>& base_zones)
	{
		if (asset_name == nullptr || std::strncmp(asset_name, "ncs_hnt_", 8) != 0)
		{
			return false;
		}

		const std::string rest = asset_name + 8;
		const auto cut = rest.find('_');
		if (cut == std::string::npos || cut == 0 || cut + 1 >= rest.size())
		{
			return false;
		}

		const auto language = rest.substr(0, cut);
		for (const auto c : language)
		{
			if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')))
			{
				return false;
			}
		}

		const auto zone = rest.substr(cut + 1);
		for (const auto& base : base_zones)
		{
			if (zone == base || zone == "patch_" + base)
			{
				return true;
			}
		}

		return false;
	}

	// Names of the zones the loader adds by hand for a `nopatch` zone, in the engine's own order (techsets_ first, cache_ next); the zone itself follows.
	inline std::vector<std::string> companion_zones(const std::string& zone)
	{
		return { "techsets_" + zone, "cache_" + zone };
	}

	// Lines in file order; blank lines, comments, a trailing CR or blanks, a UTF-8 byte order mark and repeated names are dropped (a repeat with an
	// option still turns the option on for the first one). A line that is not `<name>` with the options above (each at most once) is reported through `rejected` (when given) and left out.
	inline std::vector<entry> parse_base_entries(const std::string& text, std::vector<std::string>* rejected = nullptr)
	{
		std::vector<entry> zones;

		std::size_t begin = 0;
		if (text.size() >= 3 && text.compare(0, 3, "\xEF\xBB\xBF") == 0)
		{
			begin = 3;
		}

		while (begin <= text.size())
		{
			auto end = text.find('\n', begin);
			if (end == std::string::npos)
			{
				end = text.size();
			}

			auto line = text.substr(begin, end - begin);
			begin = end + 1;

			while (!line.empty() && (line.back() == '\r' || line.back() == ' ' || line.back() == '\t'))
			{
				line.pop_back();
			}

			std::size_t start = 0;
			while (start < line.size() && (line[start] == ' ' || line[start] == '\t'))
			{
				++start;
			}
			line.erase(0, start);

			if (line.empty() || line.compare(0, 2, "//") == 0)
			{
				continue;
			}

			entry e;
			bool ok = true;
			const auto gap = line.find_first_of(" 	");
			if (gap == std::string::npos)
			{
				e.name = line;
			}
			else
			{
				e.name = line.substr(0, gap);
				auto options = line.substr(gap);
				std::size_t at = 0;
				while (ok)
				{
					const auto first = options.find_first_not_of(" 	", at);
					if (first == std::string::npos)
					{
						break;
					}

					auto last = options.find_first_of(" 	", first);
					if (last == std::string::npos)
					{
						last = options.size();
					}

					const auto option = options.substr(first, last - first);
					at = last;
					if (option == "nopatch" && !e.no_patch)
					{
						e.no_patch = true;
					}
					else if (option == "resident" && !e.resident)
					{
						e.resident = true;
					}
					else
					{
						ok = false;
					}
				}
			}

			if (!ok || !valid_zone_name(e.name))
			{
				if (rejected)
				{
					rejected->push_back(line);
				}
				continue;
			}

			bool seen = false;
			for (auto& zone : zones)
			{
				if (zone.name == e.name)
				{
					zone.no_patch = zone.no_patch || e.no_patch;
					zone.resident = zone.resident || e.resident;
					seen = true;
				}
			}

			if (!seen)
			{
				zones.push_back(e);
			}
		}

		return zones;
	}

	// The zone names only, in file order (the options are dropped).
	inline std::vector<std::string> parse_base_list(const std::string& text, std::vector<std::string>* rejected = nullptr)
	{
		std::vector<std::string> names;
		for (const auto& e : parse_base_entries(text, rejected))
		{
			names.push_back(e.name);
		}
		return names;
	}

	// A usermap's own patch zone: the engine queues `patch_<zone>` right after a zone's techsets, and the client only looks for a usermap's `<map>.ff`,
	// `<map>_load.ff`, `<map>_art.ff` and the pak/sound files. `patch_<map>` (a name, or a file name ending in .ff) resolves to usermaps\<map>\patch_<map>.ff;
	// anything else (another prefix, an empty or invalid map name, a folder part) gives an empty string.
	inline std::string patch_zone_path(const std::string& zone_or_file)
	{
		auto zone = zone_or_file;
		if (zone.size() > 3 && zone.compare(zone.size() - 3, 3, ".ff") == 0)
		{
			zone.resize(zone.size() - 3);
		}

		static const std::string prefix = "patch_";
		if (zone.size() <= prefix.size() || zone.compare(0, prefix.size(), prefix) != 0 || !valid_zone_name(zone))
		{
			return {};
		}

		const auto map = zone.substr(prefix.size());
		return "usermaps\\" + map + "\\" + zone + ".ff";
	}
}
