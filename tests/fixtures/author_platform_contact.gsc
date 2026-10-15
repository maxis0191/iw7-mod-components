// Source Author adapter derived from a572 / GSC23FC. Original fixture is unchanged.
// SDK owns the visual and the sole retail trigger counter; no native ABI is added.
main()
{
    if (!getdvarint("dedicated") || !getdvarint("paris_collision_player_test") || !getdvarint("paris_collision_player_anchor_current") || !getdvarint("paris_author_platform_contact") ||
        getdvar("fs_game") != "mods/sdk_author_platform" || !getdvarint("sdk_author_platform_enable") || getdvarint("sv_maxclients") != 1 ||
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
        getdvar("fs_game") == "mods/sdk_author_platform" && getdvarint("sdk_author_platform_enable") == 1 &&
        getdvarint("paris_author_platform_contact") == 1 && getdvarint("sv_maxclients") == 1 &&
        getdvar("mapname") == "cp_zmb" && getdvarint("dedicated") && getdvarint("net_port") == 27116 &&
        getdvarint("sv_lanOnly") == 1 && getdvar("net_ip") == "127.0.0.1" && getdvar("g_password") != "" &&
        getdvar("paris_collision_probe_token") == state.token && !getdvarint("sv_cheats") && !getdvarint("g_inactivity") &&
        state.player paris_test_protect() && arena_clear() && (!isdefined(state.sdk) || author_scene_valid(state));
}

author_scene_valid(state)
{
    if (!isdefined(state.sdk)) return false;
    sdk = custom_scripts\cp\sdk_author_platform::read_state(state.token);
    if (!isdefined(sdk) || sdk != state.sdk || sdk.owner != state.player || sdk.token != state.token ||
        !isdefined(sdk.model) || sdk.model getentitynumber() != sdk.entity || sdk.entity < 0 || sdk.instance_id < 0 ||
        sdk.uses < 0 || sdk.uses > 1 || distance(sdk.anchor, state.anchor) > 0.001 ||
        distance(sdk.origin, state.anchor + (0,0,96)) > 0.001 || distance(sdk.model.origin, sdk.origin) > 0.001 ||
        distance(sdk.model.angles, (0,0,0)) > 0.001 || sdk.model.scale != 1) return false;
    return true;
}

author_snapshot(state, phase)
{
    if (!safe(state) || !author_scene_valid(state)) return false;
    sdk = state.sdk;
    p = sdk.model.origin;
    print("[Author contact] VISUAL token=" + state.token + " phase=" + phase + " entity=" + sdk.entity +
        " instance=" + sdk.instance_id + " uses=" + sdk.uses + " x=" + p[0] + " y=" + p[1] + " z=" + p[2] +
        " angles=0,0,0 scale=1 game_ms=" + gettime());
    return true;
}

playable(state)
{
    if (!safe(state) || !state.player isonground()) return false;
    player = state.player;
    weapon = player getcurrentweapon();
    velocity = player getvelocity();
    return isdefined(weapon) && weapon != "" && weapon != "none" && player hasweapon(weapon) &&
        isdefined(velocity) && distance(velocity, (0,0,0)) <= 1 &&
        scripts\engine\utility::flag_exist("introscreen_over") && scripts\engine\utility::flag("introscreen_over") &&
        scripts\engine\utility::flag_exist("intro_gesture_done") && scripts\engine\utility::flag("intro_gesture_done") &&
        isdefined(player.controlsfrozen) && !player.controlsfrozen &&
        (!isdefined(player.hostmigrationcontrolsfrozen) || !player.hostmigrationcontrolsfrozen);
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
    state.sdk = undefined;
    state.sdk_armed = false;
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
            if (playable(state) && isdefined(stamp) && stamp != "" && stamp != "unavailable")
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
                        state.sdk = custom_scripts\cp\sdk_author_platform::create_visual(state.player, state.anchor, state.token);
                        if (!author_scene_valid(state) || state.sdk.uses != 0 || state.sdk.armed) { fail(state, "sdk_visual_admission"); return; }
                        if (!author_snapshot(state, "prepared")) { fail(state, "sdk_prepared_snapshot"); return; }
                    }
                    if (!author_scene_valid(state) || state.sdk.uses != 0) { fail(state, "sdk_readiness_changed"); return; }
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
    if (!author_snapshot(state, "F0")) { fail(state, "sdk_F0_snapshot"); return; }
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
    if (!author_snapshot(state, "F1")) { fail(state, "sdk_F1_snapshot"); return; }
    print("[Collision player] READY_F1 token=" + state.token);
    moved = false;
    requested = false;
    previous_use = state.player usebuttonpressed();
    previous_input_ms = gettime();
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
        if (use_now && !previous_use)
        {
            if (!state.sdk_armed || requested) { fail(state, "early_or_repeated_use_edge"); return; }
            requested = true;
            state.edge_ms = gettime();
            state.edge_from_ms = previous_input_ms;
            print("[Author contact] USE_EDGE token=" + state.token + " entity=" + state.sdk.entity + " instance=" + state.sdk.instance_id +
                " sequence=1 from_ms=" + state.edge_from_ms + " game_ms=" + state.edge_ms);
        }
        previous_use = use_now;
        previous_input_ms = gettime();
        if (moved && abs(vel[0]) <= 1 && abs(vel[1]) <= 1 && abs(vel[2]) <= 1)
        {
            if (stable < 0) stable = gettime();
            if (gettime() - stable >= 250 && !state.sdk_armed && !use_now)
            {
                if (!custom_scripts\cp\sdk_author_platform::arm_use(state.sdk, state.player)) { fail(state, "sdk_arm_refused"); return; }
                state.sdk_armed = true;
                print("[Author contact] USE_ARMED token=" + state.token + " entity=" + state.sdk.entity + " instance=" + state.sdk.instance_id +
                    " released=1 stable_ms=" + (gettime() - stable) + " game_ms=" + state.sdk.armed_ms);
            }
            if (requested && !use_now && gettime() - stable >= 250)
            {
                if (!author_scene_valid(state) || state.sdk.uses > 1) { fail(state, "sdk_use_ownership"); return; }
                if (state.sdk.uses == 1)
                {
                    if (state.sdk.armed || state.sdk.last_player != state.player || state.sdk.last_token != state.token ||
                        state.sdk.last_entity != state.sdk.entity || state.sdk.last_use_ms <= state.sdk.armed_ms || state.sdk.last_use_ms > gettime() ||
                        state.sdk.last_use_ms < state.edge_from_ms || state.sdk.last_use_ms > state.edge_ms + 100)
                    { fail(state, "sdk_use_ack"); return; }
                    print("[Author contact] USE_ACK token=" + state.token + " entity=" + state.sdk.entity + " instance=" + state.sdk.instance_id + " uses=1 retail_trigger=1 game_ms=" + state.sdk.last_use_ms);
                    break;
                }
            }
        }
        else stable = -1;
        wait 0.05;
    }
    if (!moved || !requested || state.player usebuttonpressed() || stable < 0 || gettime() - stable < 250 || !safe(state) || gettime() >= deadline || gettime() >= state.deadline)
    { fail(state, "movement_or_removal_request"); return; }
    if (!state.sdk_armed || !author_scene_valid(state) || state.sdk.uses != 1) { fail(state, "sdk_use_incomplete"); return; }
    print("[Collision player] MOVED token=" + state.token);
    removed = state.owner collision_clearboxprobe();
    if (!isdefined(removed) || removed != 1) { fail(state, "native_removal"); return; }
    print("[Collision player] REMOVED token=" + state.token + " owner_alive=1");
    if (!author_snapshot(state, "F2")) { fail(state, "sdk_F2_snapshot"); return; }
    if (!fall(state, "F2", state.anchor[2], 250)) { fail(state, "removed_fall"); return; }
    state.owner delete();
    state.owner = undefined;
    print("[Collision player] OWNER_DELETED token=" + state.token);
    if (!author_snapshot(state, "after_fall")) { fail(state, "sdk_final_snapshot"); return; }
    if (!custom_scripts\cp\sdk_author_platform::teardown(state.sdk)) { fail(state, "sdk_teardown_pending"); return; }
    print("[Author contact] VISUAL_REMOVED token=" + state.token + " uses=1");
    print("[Collision player] DONE token=" + state.token);
}

fail(state, reason)
{
    state.failed = true;
    print("[Collision player] FAIL token=" + state.token + " reason=" + reason);
    if (isdefined(state.owner))
    {
        state.owner collision_clearboxes();
        state.owner delete();
        state.owner = undefined;
    }
    if (isdefined(state.sdk)) custom_scripts\cp\sdk_author_platform::teardown(state.sdk);
}
