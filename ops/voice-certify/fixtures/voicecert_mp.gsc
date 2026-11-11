// Voice certification fixture for Multiplayer. Private test dedicated only, never deployed.
// Installed by Invoke-VoiceCertify.ps1 as iw7-mod/custom_scripts/mp/voicecert_mp.gsc.
// Protection: players take no damage, the retail idle check is off and no bots join.
// Team control uses the retail team
// change path (scripts\mp\menus::setteam), the same one the team menu runs.
// Requests arrive in the dvar voicecert_req as "<seq> <verb> [arg]":
//   status | teams same | teams opposite | endgame
// Replies and a 1 s heartbeat go to stdout.

init()
{
    if (!armed())
        return;

    // A matchmaking server (every iw7-mod dedicated) runs scripts\mp\teams::watchafk: a player
    // with no kill or assist who has not moved for 60 s of play is kicked (EXE_PLAYERKICKED_INACTIVE,
    // live run final-base-1). It is the only copy in the retail scripts.
    replacefunc(scripts\mp\teams::checkforafk, ::no_afk_check);
    // iw7-mod's cdata/custom_scripts/mp/bots.gsc fills a dedicated with bots (bots_enabled is
    // registered true and read-only): 15 bots took every free slot in final-base-1. This later
    // replacement wins over its own; the heartbeat's ai= proves it.
    replacefunc(scripts\mp\bots\bots::bot_connect_monitor, ::no_bot_monitor);
    level thread protect();
    level thread heartbeat();
    level thread requests();
    print("[voicecert] armed mode=mp map=" + getdvar("mapname") + " gt=" + getdvar("g_gametype") + " port=" + getdvarint("net_port"));
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
        // gametypes assign their own damage callback during init; keep ours on top
        level.callbackplayerdamage = ::no_player_damage;
        wait 0.25;
    }
}

no_afk_check()
{
}

no_bot_monitor(num_ally_bots, num_enemy_bots)
{
}

no_player_damage(inflictor, attacker, damage, flags, mod, weapon, point, dir, hitloc, timeoffset, modelindex, partname)
{
}

heartbeat()
{
    for (;;)
    {
        line = "[voicecert] hb t=" + gettime() + " mode=mp map=" + getdvar("mapname") + " gt=" + getdvar("g_gametype") + " n=" + level.players.size;
        ai = 0;
        foreach (player in level.players)
        {
            if (isdefined(player) && isai(player))
                ai++;
        }
        line = line + " ai=" + ai;

        foreach (player in level.players)
        {
            if (isdefined(player))
                line = line + " p=" + describe(player);
        }

        print(line);
        wait 1;
    }
}

// clientnum,team,sessionstate,alive,health,sessionteam
describe(player)
{
    team = "none";
    if (isdefined(player.team))
        team = player.team;

    state = "none";
    if (isdefined(player.sessionstate))
        state = player.sessionstate;

    sessionteam = "none";
    if (isdefined(player.sessionteam))
        sessionteam = player.sessionteam;

    return player getentitynumber() + "," + team + "," + state + "," + isalive(player) + "," + player.health + "," + sessionteam;
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

        result = handle(tokens);
        print("[voicecert] ack " + tokens[0] + " " + tokens[1] + " " + result);
    }
}

handle(tokens)
{
    verb = tokens[1];

    if (verb == "status")
        return "ok";

    if (verb == "teams" && tokens.size >= 3)
        return set_teams(tokens[2]);

    if (verb == "endgame")
    {
        // retail "host ended game": intermission makes everyone hear everyone
        level thread scripts\mp\gamelogic::forceend();
        return "ok";
    }

    return "fail unknown";
}

// "same": everyone on allies. "opposite": lowest client number on allies, the next on axis.
set_teams(layout)
{
    if (layout != "same" && layout != "opposite")
        return "fail layout";

    if (!level.teambased)
        return "fail not_teambased";

    players = sorted_players();
    if (players.size < 2)
        return "fail players=" + players.size;

    for (i = 0; i < players.size; i++)
    {
        team = wanted_team(layout, i);
        if (!isdefined(players[i].team) || players[i].team != team)
            players[i] thread scripts\mp\menus::setteam(team);
    }

    // the switch kills the player; wait for the retail respawn on the new team
    deadline = gettime() + 30000;
    while (gettime() < deadline)
    {
        ready = 1;
        for (i = 0; i < players.size; i++)
        {
            team = wanted_team(layout, i);
            if (!isdefined(players[i]) || !isdefined(players[i].team) || players[i].team != team
                || !isdefined(players[i].sessionteam) || players[i].sessionteam != team
                || !isalive(players[i]) || players[i].sessionstate != "playing")
                ready = 0;
        }

        if (ready)
            return "ok";

        wait 0.25;
    }

    return "fail timeout";
}

wanted_team(layout, index)
{
    if (layout == "opposite" && index % 2 == 1)
        return "axis";

    return "allies";
}

sorted_players()
{
    sorted = [];

    foreach (player in level.players)
    {
        if (!isdefined(player))
            continue;

        index = sorted.size;
        while (index > 0 && sorted[index - 1] getentitynumber() > player getentitynumber())
        {
            sorted[index] = sorted[index - 1];
            index--;
        }

        sorted[index] = player;
    }

    return sorted;
}
