// Voice certification fixture for Zombies. Private test dedicated only, never deployed.
// Installed by Invoke-VoiceCertify.ps1 as iw7-mod/custom_scripts/cp/voicecert_cp.gsc.
// Protection: players take no damage, zombies are not spawned, the retail
// inactivity kick is fed. Requests arrive in the dvar voicecert_req as
// "<seq> <verb> [arg]"; replies and a 1 s heartbeat go to stdout.

init()
{
    if (!armed())
        return;

    level thread protect();
    level thread heartbeat();
    level thread requests();
    print("[voicecert] armed mode=cp map=" + getdvar("mapname") + " port=" + getdvarint("net_port"));
}

armed()
{
    port = getdvarint("net_port");

    if (getdvarint("voicecert_enable") != 1)
        return 0;

    if (!getdvarint("dedicated") || port < 27100 || port > 27999 || getdvar("g_password") == ""
        || getdvarint("sv_cheats") != 0 || getdvarint("sv_lanOnly") != 1)
    {
        print("[voicecert] refused: not a private protected test dedicated");
        return 0;
    }

    return 1;
}

protect()
{
    for (;;)
    {
        // maps assign their own damage callback during init; keep ours on top
        level.callbackplayerdamage = ::no_player_damage;
        level.zombies_paused = 1;
        level.nuke_zombies_paused = 1;

        if (scripts\engine\utility::flag_exist("pause_wave_progression"))
            scripts\engine\utility::flag_set("pause_wave_progression");

        foreach (player in level.players)
        {
            if (!isdefined(player))
                continue;

            player.ignoreme = 1;
            // retail kick_for_inactivity resets its countdown on this notify
            player notify("inputReceived");
        }

        wait 0.25;
    }
}

no_player_damage(inflictor, attacker, damage, flags, mod, weapon, point, dir, hitloc, timeoffset, modelindex, partname)
{
}

heartbeat()
{
    for (;;)
    {
        line = "[voicecert] hb t=" + gettime() + " mode=cp map=" + getdvar("mapname") + " gt=" + getdvar("g_gametype") + " n=" + level.players.size;

        foreach (player in level.players)
        {
            if (isdefined(player))
                line = line + " p=" + describe(player);
        }

        print(line);
        wait 1;
    }
}

// clientnum,team,sessionstate,alive,health,laststand
describe(player)
{
    team = "none";
    if (isdefined(player.team))
        team = player.team;

    state = "none";
    if (isdefined(player.sessionstate))
        state = player.sessionstate;

    laststand = 0;
    if (isdefined(player.inlaststand) && player.inlaststand)
        laststand = 1;

    return player getentitynumber() + "," + team + "," + state + "," + isalive(player) + "," + player.health + "," + laststand;
}

requests()
{
    // a request survives map changes in the dvar; never replay it
    last = getdvar("voicecert_req");

    for (;;)
    {
        wait 0.25;

        request = getdvar("voicecert_req");
        if (request == last)
            continue;

        last = request;
        tokens = strtok(request, " ");
        if (tokens.size < 2)
        {
            print("[voicecert] ack " + request + " ? fail malformed");
            continue;
        }

        result = "fail unknown";
        if (tokens[1] == "status")
            result = "ok";

        print("[voicecert] ack " + tokens[0] + " " + tokens[1] + " " + result);
    }
}
