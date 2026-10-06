#include "../../src/native/agent_scenario.hpp"
#include <cassert>
#include <iostream>
#include <vector>
#include <utility>

int main()
{
    using namespace iw7::agent;
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
        assert(parse(wire("1 1 hold " + std::string(names[i]) + " 5000"), r));
        assert(static_cast<unsigned>(r.key) == i);
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
