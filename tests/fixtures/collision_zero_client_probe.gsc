main()
{
    if (!getdvarint("dedicated") || !getdvarint("paris_collision_test"))
        return;
    level thread collision_probe();
}

collision_trace(phase, point_name, x, y, token)
{
    // Same retail point query before, during and after our body exists.
    trace = bullettrace((x, y, 4176), (x, y, 4016), 0, undefined);
    println("[Collision probe] TRACE token=" + token + " phase=" + phase +
        " point=" + point_name + " fraction=" + trace["fraction"]);
}

collision_probe()
{
    level endon("game_ended");
    token = getdvar("paris_collision_probe_token");
    println("[Collision probe] READY token=" + token);
    deadline = gettime() + 120000;
    while (!getdvarint("paris_collision_probe_arm") && gettime() < deadline)
        wait 0.05;
    players = getentarray("player", "classname");
    if (!getdvarint("paris_collision_probe_arm") || players.size ||
        getdvarint("sv_cheats") || getdvarint("g_inactivity") ||
        !getdvarint("sv_lanOnly") || getdvar("net_ip") != "127.0.0.1" ||
        getdvar("g_password") == "")
    {
        println("[Collision probe] FAIL token=" + token + " reason=admission");
        return;
    }
    println("[Collision probe] SAFETY token=" + token + " clients=0 cheats=0 inactivity=0");
    collision_trace("before", "center", 0, 0, token);
    collision_trace("before", "edge", 220, 160, token);
    floor = spawn("script_model", (0, 0, 4088));
    floor solid();
    instance = floor collision_createbox((-256, -192, 4080), (256, 192, 4096));
    if (!isdefined(instance))
    {
        println("[Collision probe] FAIL token=" + token + " reason=create_refused");
        floor collision_clearboxes();
        floor delete();
        return;
    }
    println("[Collision probe] CREATED token=" + token + " instance=" + instance);
    collision_trace("inside", "center", 0, 0, token);
    collision_trace("inside", "edge", 220, 160, token);
    executecommand("collision_box_probe 0 " + instance);
    wait 1;
    floor collision_clearboxes();
    floor delete();
    collision_trace("after", "center", 0, 0, token);
    collision_trace("after", "edge", 220, 160, token);
    players = getentarray("player", "classname");
    if (players.size || getdvarint("sv_cheats") || getdvarint("g_inactivity"))
    {
        println("[Collision probe] FAIL token=" + token + " reason=final_safety");
        return;
    }
    println("[Collision probe] DONE token=" + token);
}
