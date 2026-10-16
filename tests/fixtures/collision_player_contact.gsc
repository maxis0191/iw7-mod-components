// Private authoritative movement witness. No client collider or prediction claim.
main()
{
    if (!getdvarint("dedicated") || !getdvarint("paris_collision_player_test") || !getdvarint("paris_collision_player_anchor_current") ||
        !getdvarint("paris_isolated_lab") || getdvar("mapname") != "cp_zmb" ||
        getdvarint("net_port") != 27116 || getdvarint("sv_lanOnly") != 1 ||
        getdvar("net_ip") != "127.0.0.1" || getdvar("g_password") == "" ||
        getdvarint("sv_cheats") || getdvarint("g_inactivity")) return;
    level thread quiet_arena();
    level thread contact();
}

quiet_arena()
{
    level endon("game_ended");
    for (;;)
    {
        draining = false;
        if (isdefined(level._id_50F8) && level._id_50F8 > 0) draining = true;
        if (isdefined(level._id_E1CC) && level._id_E1CC > 0) draining = true;
        if (isdefined(level.agentarray)) foreach (actor in level.agentarray)
            if (isdefined(actor) && isalive(actor) && isdefined(actor.team) && actor.team == "axis") draining = true;
        // Existing noncombat drain ordering; never overwrite spawn counters.
        level.zombies_paused = !draining;
        level.nuke_zombies_paused = !draining;
        level.stop_spawning = 1;
        level.max_static_spawned_enemies = 0;
        level.max_dynamic_spawners = 0;
        if (isdefined(level.flag) && isdefined(level.flag["pause_wave_progression"])) level.flag["pause_wave_progression"] = true;
        if (isdefined(level.agentarray)) foreach (actor in level.agentarray)
            if (isdefined(actor) && isalive(actor) && isdefined(actor.team) && actor.team == "axis" && isdefined(actor.agent_type) &&
                (actor.agent_type == "generic_zombie" || actor.agent_type == "zombie_cop" || actor.agent_type == "zombie_clown"))
            {
                actor.died_poorly = 1;
                actor dodamage(actor.health + 980, actor.origin, actor, actor, "MOD_SUICIDE");
            }
        wait 0.05;
    }
}

arena_clear()
{
    if (!isdefined(level._id_50F8) || !isdefined(level._id_E1CC) || level._id_50F8 != 0 || level._id_E1CC != 0) return false;
    if (isdefined(level.agentarray)) foreach (actor in level.agentarray)
        if (isdefined(actor) && isalive(actor) && isdefined(actor.team) && actor.team == "axis") return false;
    return true;
}

safe(state)
{
    players = getentarray("player", "classname");
    return !state.failed && isdefined(state.player) && isalive(state.player) && players.size == 1 && players[0] == state.player &&
        getdvar("mapname") == "cp_zmb" && getdvarint("dedicated") && getdvarint("net_port") == 27116 &&
        getdvarint("sv_lanOnly") == 1 && getdvar("net_ip") == "127.0.0.1" && getdvar("g_password") != "" &&
        getdvar("paris_collision_probe_token") == state.token && !getdvarint("sv_cheats") && !getdvarint("g_inactivity") &&
        state.player paris_test_protect() && arena_clear();
}

playable(state)
{
    // Reset on every evaluation. Diagnostics never re-query a failed predicate.
    state.readiness_weapon_predicate = "not_evaluated";
    state.readiness_first_failure = "safe";
    if (!safe(state)) return false;
    state.readiness_first_failure = "ground";
    if (!state.player isonground()) return false;
    player = state.player;
    weapon = player getcurrentweapon();
    velocity = player getvelocity();
    // Keep both original eager getters above, including when weapon is invalid.
    state.readiness_first_failure = "weapon";
    state.readiness_weapon_predicate = "undefined";
    if (!isdefined(weapon)) return false;
    state.readiness_weapon_predicate = "empty";
    if (!(weapon != "")) return false;
    state.readiness_weapon_predicate = "none";
    if (!(weapon != "none")) return false;
    state.readiness_weapon_predicate = "not_owned";
    if (!(player hasweapon(weapon))) return false;
    state.readiness_weapon_predicate = "passed";
    state.readiness_first_failure = "velocity";
    if (!(isdefined(velocity) && distance(velocity, (0,0,0)) <= 1)) return false;
    state.readiness_first_failure = "intro_screen";
    if (!(scripts\engine\utility::flag_exist("introscreen_over") && scripts\engine\utility::flag("introscreen_over"))) return false;
    state.readiness_first_failure = "intro_gesture";
    if (!(scripts\engine\utility::flag_exist("intro_gesture_done") && scripts\engine\utility::flag("intro_gesture_done"))) return false;
    state.readiness_first_failure = "controls";
    if (!(isdefined(player.controlsfrozen) && !player.controlsfrozen)) return false;
    state.readiness_first_failure = "hostmigration";
    if (!(!isdefined(player.hostmigrationcontrolsfrozen) || !player.hostmigrationcontrolsfrozen)) return false;
    state.readiness_first_failure = "ready";
    return true;
}

sample(state, phase)
{
    if (!safe(state)) return false;
    player = state.player;
    stamp = player paris_agent_observationstamp();
    if (!isdefined(stamp) || stamp == "" || stamp == "unavailable") return false;
    pos = player.origin;
    vel = player getvelocity();
    if (!isdefined(vel)) return false;
    state.sample_id++;
    print("[Collision player] SAMPLE token=" + state.token + " phase=" + phase + " sample=" + state.sample_id + "; " + stamp +
        "; game_ms=" + gettime() + "; x=" + pos[0] + "; y=" + pos[1] + "; z=" + pos[2] +
        "; vx=" + vel[0] + "; vy=" + vel[1] + "; vz=" + vel[2] + "; ground=" + (player isonground()));
    print("[Paris agent heartbeat] map=cp_zmb; " + player paris_test_safety_snapshot());
    return true;
}

fall(state, phase, landing_z, stable_ms)
{
    deadline = gettime() + 4000;
    stable = -1;
    crossed = false;
    falling = false;
    while (gettime() < deadline && gettime() < state.deadline)
    {
        if (!sample(state, phase)) return false;
        pos = state.player.origin;
        vel = state.player getvelocity();
        if (vel[2] < -8) falling = true;
        if (phase == "F1" || pos[2] < state.top - 8) crossed = true;
        if (abs(pos[0] - state.anchor[0]) > 64 || abs(pos[1] - state.anchor[1]) > 64) return false;
        if (falling && crossed && state.player isonground() && abs(pos[2] - landing_z) <= 4 && abs(vel[2]) <= 1)
        {
            if (stable < 0) stable = gettime();
            if (gettime() - stable >= stable_ms) return true;
        }
        else stable = -1;
        wait 0.05;
    }
    return false;
}

place(state, phase)
{
    // The only position writes, explicitly between measurement intervals.
    print("[Collision player] PLACED token=" + state.token + " phase=" + phase + " x=" + state.start[0] + " y=" + state.start[1] + " z=" + state.start[2]);
    state.player setorigin(state.start);
    wait 0.05;
}

audit(state)
{
    if (!safe(state)) return false;
    a = state.anchor;
    offsets = [];
    offsets[0] = (0,0,0);
    offsets[1] = (112,112,0);
    offsets[2] = (112,-112,0);
    offsets[3] = (-112,112,0);
    offsets[4] = (-112,-112,0);
    foreach (offset in offsets)
    {
        p = a + offset;
        ground = bullettrace(p + (0,0,48), p - (0,0,32), 0, undefined);
        clear = bullettrace(p + (0,0,256), p + (0,0,32), 0, undefined);
        if (!isdefined(ground["position"]) || ground["fraction"] >= 1 || abs(ground["position"][2] - a[2]) > 4 ||
            ground["normal"][2] < 0.9 || clear["fraction"] != 1) return false;
    }
    print("[Collision player] AUDIT token=" + state.token + " x=" + a[0] + " y=" + a[1] + " z=" + a[2] + " ground_points=5 vertical_clear=5");
    return true;
}

contact()
{
    level endon("game_ended");
    state = spawnstruct();
    state.failed = false;
    state.sample_id = 0;
    state.token = getdvar("paris_collision_probe_token");
    state.anchor_frozen = false;
    state.owner = undefined;
    deadline = gettime() + 180000;
    stable = -1;
    print("[Collision player] READY token=" + state.token);
    while (gettime() < deadline)
    {
        players = getentarray("player", "classname");
        if (players.size == 1)
        {
            if (state.anchor_frozen && state.player != players[0]) { fail(state, "anchor_player_changed"); return; }
            state.player = players[0];
            state.player paris_test_protect();
            print("[Paris agent heartbeat] map=cp_zmb; " + state.player paris_test_safety_snapshot());
            stamp = state.player paris_agent_observationstamp();
            playable_now = playable(state);
            state.readiness_stamp_state = "undefined";
            if (isdefined(stamp))
            {
                state.readiness_stamp_state = "available";
                if (stamp == "") state.readiness_stamp_state = "empty";
                else if (stamp == "unavailable") state.readiness_stamp_state = "unavailable";
            }
            if (playable_now && isdefined(stamp) && stamp != "" && stamp != "unavailable")
            {
                if (state.anchor_frozen && distance(state.player.origin, state.anchor) > 1) { fail(state, "anchor_pose_changed_before_arm"); return; }
                if (stable < 0) stable = gettime();
                if (gettime() - stable >= 1000)
                {
                    if (!state.anchor_frozen)
                    {
                        // Existing retail getter, before either declared placement.
                        state.anchor = state.player.origin;
                        state.start = state.anchor + (0,0,208);
                        state.top = state.anchor[2] + 112;
                        state.anchor_frozen = true;
                    }
                    print("[Collision player] PLAYER_READY token=" + state.token + "; " + stamp +
                        "; anchor_x=" + state.anchor[0] + "; anchor_y=" + state.anchor[1] + "; anchor_z=" + state.anchor[2]);
                    if (getdvarint("paris_collision_probe_arm")) break;
                }
            }
            else
            {
                if (state.anchor_frozen) { fail(state, "frozen_anchor_readiness_lost"); return; }
                stable = -1;
            }
        }
        else
        {
            if (state.anchor_frozen) { fail(state, "frozen_anchor_player_lost"); return; }
            stable = -1;
        }
        wait 0.05;
    }
    if (gettime() >= deadline || !audit(state)) { fail(state, "admission_or_clearance"); return; }
    state.deadline = gettime() + 25000;
    place(state, "F0");
    if (!fall(state, "F0", state.anchor[2], 250)) { fail(state, "absent_fall"); return; }
    print("[Collision player] F0_CLEAR token=" + state.token);
    state.owner = spawn("script_model", state.anchor + (0,0,104));
    state.owner solid();
    instance = state.owner collision_createbox(state.anchor + (-128,-128,96), state.anchor + (128,128,112), 1);
    if (!isdefined(instance)) { fail(state, "create_refused"); return; }
    print("[Collision player] CREATED token=" + state.token + " instance=" + instance);
    executecommand("collision_box_probe 0 " + instance);
    wait 0.1;
    place(state, "F1");
    if (!fall(state, "F1", state.top, 600)) { fail(state, "present_landing"); return; }
    base = state.player.origin;
    print("[Collision player] READY_F1 token=" + state.token);
    moved = false;
    requested = false;
    previous_use = state.player usebuttonpressed();
    stable = -1;
    deadline = gettime() + 8000;
    while (gettime() < deadline && gettime() < state.deadline)
    {
        if (!sample(state, "F1")) { fail(state, "standing_protection"); return; }
        pos = state.player.origin;
        vel = state.player getvelocity();
        displacement = distance((pos[0],pos[1],0), (base[0],base[1],0));
        if (displacement > 64 || abs(pos[2] - state.top) > 4 || !state.player isonground()) { fail(state, "top_contact_lost"); return; }
        if (displacement >= 4) moved = true;
        use_now = state.player usebuttonpressed();
        if (use_now && !previous_use) requested = true;
        previous_use = use_now;
        if (moved && abs(vel[0]) <= 1 && abs(vel[1]) <= 1 && abs(vel[2]) <= 1)
        {
            if (stable < 0) stable = gettime();
            if (requested && !use_now && gettime() - stable >= 250) break;
        }
        else stable = -1;
        wait 0.05;
    }
    if (!moved || !requested || state.player usebuttonpressed() || stable < 0 || gettime() - stable < 250 || !safe(state) || gettime() >= deadline || gettime() >= state.deadline)
    { fail(state, "movement_or_removal_request"); return; }
    print("[Collision player] MOVED token=" + state.token);
    removed = state.owner collision_clearboxprobe();
    if (!isdefined(removed) || removed != 1) { fail(state, "native_removal"); return; }
    print("[Collision player] REMOVED token=" + state.token + " owner_alive=1");
    if (!fall(state, "F2", state.anchor[2], 250)) { fail(state, "removed_fall"); return; }
    state.owner delete();
    state.owner = undefined;
    print("[Collision player] OWNER_DELETED token=" + state.token);
    print("[Collision player] DONE token=" + state.token);
}

fail(state, reason)
{
    state.failed = true;
    line = "[Collision player] FAIL token=" + state.token + " reason=" + reason;
    if (reason == "frozen_anchor_readiness_lost")
    {
        line += " readiness_group=" + state.readiness_first_failure + " stamp_state=" + state.readiness_stamp_state;
        if (state.readiness_first_failure == "weapon")
            line += " weapon_predicate=" + state.readiness_weapon_predicate;
    }
    print(line);
    if (isdefined(state.owner))
    {
        state.owner collision_clearboxes();
        state.owner delete();
        state.owner = undefined;
    }
}
