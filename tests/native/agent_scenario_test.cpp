#include "../../src/native/agent_scenario.hpp"
#include "../../src/native/paris_model_diagnostics.hpp"
#include <cassert>
#include <iostream>
#include <vector>
#include <utility>

int main()
{
    using namespace iw7::agent;
    // Server heartbeat freshness cannot authorize a stale CLIENT query cache.
    using namespace paris_model_diagnostics;
    scene_capture_facts capture{};
    capture.now = 1406; capture.query_tick = 1000; capture.arm = 6; capture.flags = 31;
    capture.active_arm = capture.protected_now = capture.identity_valid = capture.cp_mode = true;
    capture.client_active = capture.cgame_initialized = capture.connection_active = capture.rig_fs_game = true;
    const auto refused_as = [](const char* value, std::string_view expected) {
        return value && std::string_view(value) == expected;
    };
    assert(scene_capture_refusal(capture) == nullptr); // Existing 500ms ARM/input scope.
    assert(refused_as(scene_query_refusal(capture.query_tick, capture.now, 250), "query_age_250"));
    const auto fresh_server_heartbeat = capture.now;
    assert(fresh_server_heartbeat == capture.now &&
        refused_as(scene_query_refusal(capture.query_tick, capture.now, 250), "query_age_250"));
    capture.now = 1250;
    assert(scene_query_refusal(capture.query_tick, capture.now, 250) == nullptr);
    capture.now = 1251;
    assert(refused_as(scene_query_refusal(capture.query_tick, capture.now, 250), "query_age_250"));
    capture.now = 1500; assert(scene_capture_refusal(capture) == nullptr);
    capture.now = 1501; assert(refused_as(scene_capture_refusal(capture), "query_age_500"));
    capture.now = 999; assert(refused_as(scene_capture_refusal(capture), "query_tick_future"));
    capture.now = 1100; capture.query_tick = 0;
    assert(refused_as(scene_capture_refusal(capture), "query_tick_missing"));
    capture.query_tick = 1000; capture.active_arm = false;
    assert(refused_as(scene_capture_refusal(capture), "inactive_arm"));
    capture.active_arm = true; capture.flags = 7;
    assert(refused_as(scene_capture_refusal(capture), "scope_flags"));
    capture.flags = 15; capture.cp_mode = false;
    assert(refused_as(scene_capture_refusal(capture), "game_mode"));
    capture.cp_mode = true; capture.shutdown = true;
    assert(refused_as(scene_capture_refusal(capture), "observer_shutdown"));
    const std::string nonce(32, 'a');
    std::uint32_t key_offset = 0xFFFFFFFF;
    assert(movement_key_offset(button::forward, key_offset) && key_offset == 0);
    assert(movement_key_offset(button::back, key_offset) && key_offset == 0x14);
    assert(movement_key_offset(button::left, key_offset) && key_offset == 0x50);
    assert(movement_key_offset(button::right, key_offset) && key_offset == 0x64);
    assert(!movement_key_offset(button::fire, key_offset) && key_offset == 0x64);
    assert(!movement_key_offset(button::none, key_offset));
    assert(!movement_key_offset(static_cast<button>(999), key_offset));
    // Upstream crypto is an independently initialized translation-unit global.
    // The native adapter's global lab_session must not touch it during CRT init.
    unsigned generated{}; bool crypto_ready{};
    const auto generate = [&]() { assert(crypto_ready); ++generated; return nonce; };
    lab_session lazy;
    assert(!lazy.client && lazy.client_nonce.empty() && lazy.server_generation.empty() && generated == 0);
    lazy.activate(42, false, false, generate); // Ordinary profiles are inert even before crypto readiness.
    assert(generated == 0 && !lazy.client);
    crypto_ready = true;
    lazy.activate(42, false, true, generate);
    assert(generated == 1 && !lazy.client && lazy.client_nonce.empty() && lazy.server_generation == nonce);
    lazy.activate(42, false, true, generate); assert(generated == 1); // Repeat lifecycle callback is idempotent.
    lazy.activate(42, true, false, generate);
    assert(generated == 2 && lazy.client && lazy.client_nonce == nonce && !lazy.client->active());
    lazy.activate(42, true, true, generate); assert(generated == 2);
    // Server stamps authorize only a fresh original single-slot observation.
    assert(observation_valid(nonce, nonce, 0, 1000, 1500, true, true));
    assert(!observation_valid(nonce, nonce, 0, 1000, 1501, true, true));
    assert(!observation_valid(nonce, nonce, 0, 1000, 999, true, true));
    assert(!observation_valid(nonce, nonce, 1, 1000, 1000, true, true));
    assert(!observation_valid(nonce, nonce, 0, 1000, 1000, false, true));
    assert(!observation_valid(nonce, nonce, 0, 1000, 1000, true, false));
    assert(!observation_valid("", nonce, 0, 1000, 1000, true, true));
    assert(observation_valid(nonce, nonce, 0, 1000, 1500, true, true, true));
    assert(observation_valid(nonce, nonce, 1, 1000, 1500, true, true, true));
    assert(!observation_valid(nonce, nonce, 2, 1000, 1000, true, true, true));
    assert(!observation_valid(nonce, nonce, 1, 1000, 1501, true, true, true));
    assert(!observation_valid(nonce, nonce, 1, 1000, 999, true, true, true));
    assert(!observation_valid(nonce, "", 1, 1000, 1000, true, true, true));
    assert(!observation_valid(nonce, nonce, 1, 1000, 1000, false, true, true));
    assert(!observation_valid(nonce, nonce, 1, 1000, 1000, true, false, true));
    assert(revive_role_enabled("1"));
    for (const auto value : {"", "0", "01", "true", "1 ", " 1"}) assert(!revive_role_enabled(value));
    assert(unique_slot({false, false, false, false}) == -1);
    assert(unique_slot({true, false, false, false}) == 0);
    assert(unique_slot({false, true, false, false}) == 1);
    assert(unique_slot({true, true, false, false}) == -1);
    assert(unique_slot({false, true, true, false}) == -1);
    using paris_model_diagnostics::span_within;
    assert(span_within(4096, 4096, 4096, 4096));
    assert(span_within(8191, 1, 4096, 4096));
    assert(!span_within(8191, 2, 4096, 4096));
    assert(!span_within(4095, 1, 4096, 4096));
    assert(!span_within(4096, 4097, 4096, 8192));
    assert(!span_within(0, 1, 0, 4096));
    assert(!span_within(4096, 0, 4096, 4096));
    assert(!span_within(std::numeric_limits<std::uintptr_t>::max(), 1, 4096, 4096));
    // Inject dispatch latency: deadline starts after actual down, not mailbox
    // parsing. A frame check releases independently of the 50ms IO poll.
    scenario actual_run(42, nonce); safety actual_safety{true, true, "cp_zmb", 1000};
    std::vector<std::pair<button, bool>> actual_events;
    std::uint64_t actual_clock = 1000;
    const auto stamped_dispatch = [&](button key, bool down) { actual_events.emplace_back(key, down); return actual_clock; };
    assert(std::string(actual_run.accept(request{42, nonce, 1, 1, action::arm}, 1000, actual_safety, stamped_dispatch)) == "armed");
    actual_clock = 1040;
    assert(std::string(actual_run.accept(request{42, nonce, 2, 2, action::hold, button::aim_left, 40}, 1000, actual_safety, stamped_dispatch)) == "dispatched");
    assert(actual_run.due(button::aim_left) == 1080);
    assert(!actual_run.tick(1079, actual_safety, stamped_dispatch));
    actual_clock = 1081;
    assert(std::string(actual_run.tick(1081, actual_safety, stamped_dispatch)) == "step_complete");
    assert(actual_events.back() == std::make_pair(button::aim_left, false));
    actual_clock = 1601;
    assert(std::string(actual_run.accept(request{42, nonce, 3, 3, action::hold, button::aim_left, 40}, 1081, actual_safety, stamped_dispatch)) == "aborted");
    assert(!actual_run.active() && !actual_run.pending() && actual_events.back() == std::make_pair(button::aim_left, false));
    actual_clock = 2000; actual_safety.received = 2000;
    assert(std::string(actual_run.accept(request{42, nonce, 4, 4, action::arm}, 2000, actual_safety, stamped_dispatch)) == "armed");
    actual_clock = 1999;
    assert(std::string(actual_run.accept(request{42, nonce, 5, 5, action::press, button::fire}, 2000, actual_safety, stamped_dispatch)) == "clock_reversed");
    assert(!actual_run.pending() && !actual_run.active());
    const auto high = std::numeric_limits<std::uint64_t>::max(); actual_clock = high - 50; actual_safety.received = high - 100;
    assert(std::string(actual_run.accept(request{42, nonce, 6, 6, action::arm}, high - 100, actual_safety, stamped_dispatch)) == "armed");
    assert(std::string(actual_run.accept(request{42, nonce, 7, 7, action::hold, button::aim_left, 100}, high - 100, actual_safety, stamped_dispatch)) == "clock_overflow");
    assert(!actual_run.pending() && !actual_run.active());
    request r;
    const auto wire = [&](std::string tail) { return "42 " + nonce + " " + tail; };
    assert(parse(wire("1 1 arm none 0"), r));
    const auto saved = r;
    for (const auto& invalid : {"0 1 arm none 0", "1 0 arm none 0", "1 1 arm fire 0", "1 1 eval none 0",
        "1 1 hold fire 0", "1 1 hold fire 5001", "1 1 press fire 1", "1 1 press none 0", "1 1 release fire -1",
        "-1 1 arm none 0", "18446744073709551616 1 arm none 0", "1 1 arm none 0 extra"})
        assert(!parse(wire(invalid), r));
    assert(r.sequence == saved.sequence); // Failed parsing cannot partly replace a valid request.
    assert(!parse("42 " + std::string(32, 'A') + " 1 1 arm none 0", r));
    assert(!parse(std::string(257, 'x'), r));
    assert(heartbeat_valid(nonce, nonce, nonce, true, 1000, 999, 1000, 1300));
    assert(!heartbeat_valid(nonce, nonce, nonce, true, 1000, 999, 1000, 1301));
    assert(!heartbeat_valid(nonce, nonce, nonce, false, 1000, 999, 1000, 1000));
    assert(!heartbeat_valid(nonce, std::string(32, 'b'), nonce, true, 1000, 999, 1000, 1000));
    assert(!heartbeat_valid(nonce, nonce, "bad", true, 1000, 999, 1000, 1000));
    assert(!heartbeat_valid(nonce, nonce, nonce, true, 1000, 1000, 1001, 1000));
    assert(!heartbeat_valid(nonce, nonce, nonce, true, 1001, 999, 1000, 1001));
    assert(!heartbeat_valid(nonce, nonce, nonce, true, 1000, 999, 1000, 999));
    for (unsigned i = 0; i < bindings.size(); ++i)
    {
        assert(parse(wire("1 1 hold " + std::string(names[i]) + (aiming(static_cast<button>(i)) ? " 250" : " 5000")), r));
        assert(static_cast<unsigned>(r.key) == i);
    }
    for (auto key : {button::aim_left, button::aim_right, button::aim_up, button::aim_down})
    {
        assert((std::string(bindings[static_cast<unsigned>(key)]) == std::array<const char*, 4>{"+left", "+right", "+lookup", "+lookdown"}[static_cast<unsigned>(key) - static_cast<unsigned>(button::aim_left)]));
        key_probe probe{};
        assert(key_probe_for(key, probe) && probe.code + 14 + probe.displacement == probe.address);
        assert(parse(wire("1 1 hold " + std::string(names[static_cast<unsigned>(key)]) + " 250"), r));
        assert(!parse(wire("1 1 hold " + std::string(names[static_cast<unsigned>(key)]) + " 251"), r));
        std::vector<std::pair<button, bool>> aim_events;
        const auto aim_dispatch = [&](button k, bool down) { aim_events.emplace_back(k, down); };
        scenario aim_run(42, nonce); safety aim_s{true, true, "cp_zmb", 1000};
        assert(std::string(aim_run.accept({42, nonce, 1, 1, action::arm}, 1000, aim_s, aim_dispatch)) == "armed");
        assert(std::string(aim_run.accept({42, nonce, 2, 2, action::hold, key, 251}, 1000, aim_s, aim_dispatch)) == "duration_rejected");
        assert(aim_events.empty());
        assert(std::string(aim_run.accept({42, nonce, 3, 3, action::hold, key, 250}, 1000, aim_s, aim_dispatch)) == "dispatched");
        assert(!aim_run.tick(1249, aim_s, aim_dispatch));
        assert(std::string(aim_run.tick(1250, aim_s, aim_dispatch)) == "step_complete");
        assert(aim_events.size() == 2 && aim_events.back() == std::make_pair(key, false));
        assert(std::string(aim_run.accept({42, nonce, 4, 4, action::press, key}, 1250, aim_s, aim_dispatch)) == "dispatched");
        aim_s.protected_now = false;
        assert(std::string(aim_run.tick(1251, aim_s, aim_dispatch)) == "protection_lost");
        assert(!aim_run.active() && !aim_run.pending() && aim_events.back() == std::make_pair(key, false));
    }
    std::vector<std::pair<button, bool>> events;
    const auto dispatch = [&](button key, bool down) { events.emplace_back(key, down); };
    safety s{true, true, "cp_zmb", 1000};
    scenario run(42, nonce);
    auto send = [&](std::uint64_t seq, action op, button key = button::none, std::uint64_t duration = 0)
    { return run.accept(request{42, nonce, seq, seq, op, key, duration}, 1000, s, dispatch); };
    assert(std::string(send(1, action::press, button::fire)) == "not_armed");
    assert(std::string(send(2, action::arm)) == "armed");
    assert(std::string(send(2, action::press, button::fire)) == "replay_rejected");
    assert(std::string(run.accept(request{42, std::string(32, 'b'), 99, 99, action::abort}, 1000, s, dispatch)) == "identity_rejected");
    assert(run.active() && run.sequence() == 2);
    assert(std::string(run.accept(request{43, nonce, 99, 99, action::abort}, 1000, s, dispatch)) == "identity_rejected");
    assert(std::string(run.accept(request{42, nonce, 3, 2, action::abort}, 1000, s, dispatch)) == "replay_rejected");
    assert(std::string(send(3, action::press, button::fire)) == "dispatched");
    assert(events.size() == 1 && events.back() == std::make_pair(button::fire, true));
    assert(std::string(send(4, action::hold, button::forward, 5000)) == "busy_rejected");
    assert(run.sequence() == 3 && run.step() == 3);
    s.received = 1199; assert(!run.tick(1199, s, dispatch));
    s.received = 1200; assert(std::string(run.tick(1200, s, dispatch)) == "step_complete");
    assert(events.back() == std::make_pair(button::fire, false));
    // Safety expiry aborts a long hold before its requested end and releases it.
    assert(std::string(run.accept(request{42, nonce, 4, 4, action::hold, button::forward, 5000}, 1200, s, dispatch)) == "dispatched");
    assert(!run.tick(1700, s, dispatch));
    assert(std::string(run.tick(1701, s, dispatch)) == "protection_lost");
    assert(!run.active() && events.back() == std::make_pair(button::forward, false));
    s.received = 2000;
    assert(std::string(run.accept(request{42, nonce, 5, 5, action::arm}, 2000, s, dispatch)) == "armed");
    assert(std::string(run.accept(request{42, nonce, 6, 6, action::hold, button::ads, 5000}, 2000, s, dispatch)) == "dispatched");
    s.map = "cp_final"; assert(std::string(run.tick(2001, s, dispatch)) == "map_changed");
    assert(events.back() == std::make_pair(button::ads, false));
    s.received = 3000;
    assert(std::string(run.accept(request{42, nonce, 7, 7, action::arm}, 3000, s, dispatch)) == "armed");
    assert(std::string(run.accept(request{42, nonce, 8, 8, action::hold, button::left, 5000}, 3000, s, dispatch)) == "dispatched");
    assert(std::string(run.tick(2999, s, dispatch)) == "clock_reversed");
    assert(events.back() == std::make_pair(button::left, false));
    s.received = 4000;
    assert(std::string(run.accept(request{42, nonce, 9, 9, action::arm}, 4000, s, dispatch)) == "armed");
    s.received = 34000; assert(std::string(run.tick(34000, s, dispatch)) == "deadline");
    s.connected = false; s.protected_now = false;
    assert(std::string(run.accept(request{42, nonce, 10, 10, action::abort}, 35000, s, dispatch)) == "aborted");
    assert(!run.active());
    assert(!scenario::safe(s, 35000));
    s = {true, true, "cp_zmb", 36000};
    assert(!scenario::safe(s, 35999));
    assert(scenario::safe(s, 36500)); assert(!scenario::safe(s, 36501));
    assert(std::string(run.accept(request{42, nonce, 11, 11, action::arm}, 36000, s, dispatch)) == "armed");
    assert(std::string(run.accept(request{42, nonce, 12, 12, action::hold, button::use, 5000}, 36000, s, dispatch)) == "dispatched");
    s.connected = false; assert(std::string(run.tick(36001, s, dispatch)) == "protection_lost");
    assert(events.back() == std::make_pair(button::use, false));
    s = {true, true, "cp_zmb", 37000};
    assert(std::string(run.accept(request{42, nonce, 13, 13, action::arm}, 37000, s, dispatch)) == "armed");
    assert(std::string(run.accept(request{42, nonce, 14, 14, action::hold, button::reload, 5000}, 37000, s, dispatch)) == "dispatched");
    assert(std::string(run.accept(request{42, nonce, 15, 15, action::release, button::reload}, 37001, s, dispatch)) == "released");
    assert(run.active() && !run.pending());
    assert(std::string(run.accept(request{42, nonce, 16, 16, action::hold, button::jump, 5000}, 37002, s, dispatch)) == "dispatched");
    assert(std::string(run.accept(request{42, nonce, 17, 17, action::release_all}, 37003, s, dispatch)) == "released");
    assert(!run.active() && events.back() == std::make_pair(button::jump, false));
    s.map = "none"; assert(!scenario::safe(s, 37004));
    std::cout << "Agent scenario parser, identity/replay, clock/deadline, map/safety abort and automatic release passed\n";
}
