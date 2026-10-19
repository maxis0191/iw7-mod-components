// Private, zero-client native construction probe. No actor is spawned in combat.
init()
{
    if (!getdvarint("dedicated") || !getdvarint("paris_isolated_lab") ||
        getdvarint("net_port") < 27100 || getdvarint("net_port") > 27999 ||
        getdvarint("paris_capacity_pool_probe") != 1 ||
        getdvarint("paris_native_agent_capacity") != 64) return;
    level thread begin();
    if (getdvarint("paris_capacity_client_probe") == 1) level thread connections();
}

connections()
{
    level endon("game_ended");
    for (;;)
    {
        level waittill("connected", player);
        if (!isdefined(player) || !player paris_test_protect())
        {
            print("[Paris capacity client] FAIL protection_lost;");
            continue;
        }
        player thread heartbeat();
    }
}

heartbeat()
{
    self endon("disconnect");
    level endon("game_ended");
    self waittill("spawned_player");
    for (;;)
    {
        if (level.players.size != 1 || !self paris_test_protect())
        {
            print("[Paris capacity client] FAIL protection_lost;");
            return;
        }
        print("[Paris capacity heartbeat] " + self paris_test_safety_snapshot());
        wait 1;
    }
}

begin()
{
    level endon("game_ended");
    deadline = gettime() + 30000;
    while ((!isdefined(level.agentarray) || !isdefined(level.initagentscriptvariables) ||
        !isdefined(level.setagentteam)) && gettime() < deadline) wait 0.05;
    if (!isdefined(level.agentarray) || !isdefined(level.initagentscriptvariables) ||
        !isdefined(level.setagentteam) || getmaxagents() != 64)
    {
        print("[Paris capacity pool] FAIL initialization prerequisites");
        return;
    }
    while (level.agentarray.size < 64 && gettime() < deadline)
    {
        agent = addagent();
        if (!isdefined(agent))
        {
            print("[Paris capacity pool] FAIL native addagent at " + level.agentarray.size);
            return;
        }
        wait 0.05;
    }
    if (level.agentarray.size != 64 || level.numagents != 64)
    {
        print("[Paris capacity pool] FAIL native/script count differs");
        return;
    }
    array_call("READY");
    while (getdvarint("paris_capacity_pool_validate") != 1) wait 0.05;
    array_call("POST_RESTART");
    setdvar("paris_capacity_pool_validate", 2);
}

array_call(marker)
{
    if (getmaxagents() != 64 || !isdefined(level.agentarray) || level.agentarray.size != 64 || level.numagents != 64)
    {
        print("[Paris capacity pool] FAIL " + marker + " count");
        return;
    }
    seen = [];
    foreach (agent in level.agentarray)
    {
        slot = agent getentitynumber();
        if (slot < 0 || slot >= 82 || isdefined(seen[slot]))
        {
            print("[Paris capacity pool] FAIL entity bounds or duplicate");
            return;
        }
        seen[slot] = true;
    }
    print("[Paris capacity pool] " + marker + " native=64 initialized=64 unique=64 bounded=82; combat=0");
}
