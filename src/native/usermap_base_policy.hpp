#pragma once

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

	// Lines in file order; blank lines, comments, a trailing CR or blanks, a UTF-8 byte order mark and repeated names are dropped.
	// Names that are not valid zone names are reported through `rejected` (when given) and left out.
	inline std::vector<std::string> parse_base_list(const std::string& text, std::vector<std::string>* rejected = nullptr)
	{
		std::vector<std::string> zones;

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

			if (!valid_zone_name(line))
			{
				if (rejected)
				{
					rejected->push_back(line);
				}
				continue;
			}

			bool seen = false;
			for (const auto& zone : zones)
			{
				seen = seen || zone == line;
			}

			if (!seen)
			{
				zones.push_back(line);
			}
		}

		return zones;
	}
}
