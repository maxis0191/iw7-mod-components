#include "agent_scenario.hpp"
#include <stdexcept>
#include <vector>
#include <iostream>
using namespace iw7::agent;
static void check(bool value) { if(!value)throw std::runtime_error("PTT policy failed"); }
int main()
{
    request r; const std::string nonce(32,'a');
    check(parse("12 "+nonce+" 1 1 arm none 0\n",r));
    scenario s(12,nonce); safety safe;safe.connected=safe.protected_now=true;safe.map="cp_zmb";safe.received=100;
    std::vector<std::pair<button,bool>> events;
    auto dispatch=[&](button key,bool down){events.emplace_back(key,down);};
    check(std::string(s.accept(r,100,safe,dispatch))=="armed");
    check(parse("12 "+nonce+" 2 2 hold talk 400\n",r));
    check(std::string(s.accept(r,101,safe,dispatch))=="talk_rejected" && events.empty());
    r.sequence=r.step=3;safe.talk_enabled=true;
    check(std::string(s.accept(r,102,safe,dispatch))=="dispatched");
    check(events.size()==1 && events[0].first==button::talk && events[0].second);
    check(std::string(bindings[static_cast<unsigned>(button::talk)])=="+talk");
    // Audio/privacy loss releases the same ordinary key without requiring new
    // admission and cannot keep PTT stuck while the fixture tears down.
    safe.talk_enabled=false;
    check(std::string(s.tick(110,safe,dispatch))=="privacy_lost");
    check(events.size()==2 && !events.back().second && !s.active());
    safe.talk_enabled=true;safe.received=120;
    check(parse("12 "+nonce+" 4 4 arm none 0\n",r));
    check(std::string(s.accept(r,120,safe,dispatch))=="armed");
    check(parse("12 "+nonce+" 5 5 hold talk 400\n",r));
    check(std::string(s.accept(r,121,safe,dispatch))=="dispatched");
    safe.protected_now=false;safe.talk_enabled=false;
    check(parse("12 "+nonce+" 6 6 release talk 0\n",r));
    check(std::string(s.accept(r,122,safe,dispatch))=="released" && !events.back().second);
    check(parse("12 "+nonce+" 7 7 abort none 0\n",r));
    check(std::string(s.accept(r,123,safe,dispatch))=="aborted");
    check(!parse("12 "+nonce+" 8 8 hold talk 5001\n",r));
    check(parse("12 "+nonce+" 8 8 arm none 0\n",r));
    safe.protected_now=true;safe.received=130;
    check(std::string(s.accept(r,130,safe,dispatch))=="armed");
    check(parse("12 "+nonce+" 9 9 hold forward 20\n",r));
    check(std::string(s.accept(r,131,safe,dispatch))=="dispatched");
    check(std::string(s.tick(151,safe,dispatch))=="step_complete");
    std::cout<<"PASS draft talk-only admission/release/protection loss and ordinary movement unchanged; no engine/audio calls.\n";
}
