#pragma once
#include "game/game.hpp"
#include <utils/info_string.hpp>
namespace auto_capacity {
// This distribution owns its executable; the ordinary remote CB updater must
// not overwrite the extra capability with an incompatible older client.
inline constexpr bool managed_client() noexcept { return true; }
bool switch_for_server(const game::netadr_s&,const utils::info_string&);
const char* player_directory() noexcept;
}
