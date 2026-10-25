#pragma once
#include "game/game.hpp"

namespace owner_cheats
{
    bool server_allowed(int slot);
    bool client_allowed();
    void invalidate(const game::netadr_s* endpoint);
    bool give_customized(int slot, const std::vector<std::string>& params);
}
