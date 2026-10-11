#pragma once
#include <cstdint>
#include <string>
#include <sstream>
#include <limits>

namespace voice_test_binding {
struct startup_shutdown {
    bool admitted{}, main_thread{}, already_preserved{}, armed{}, cancelled{};
    bool protection_seen{}, binding_seen{}, capture_failed{};
    std::uint64_t admitted_tick{}, deadline_tick{}, observed_tick{};
};
// A single frontend-to-map shutdown may precede the first protected binding.
// This preserves only silent startup; it grants no capture ARM or PTT authority.
inline bool preserve_startup_shutdown(const startup_shutdown& s) {
    return s.admitted && s.main_thread && !s.already_preserved && !s.armed && !s.cancelled &&
        !s.protection_seen && !s.binding_seen && !s.capture_failed && s.admitted_tick &&
        s.deadline_tick>=s.admitted_tick && s.deadline_tick-s.admitted_tick==120000 &&
        s.observed_tick>=s.admitted_tick && s.observed_tick<=s.deadline_tick;
}
struct observation {
    bool relay_ready{}, loopback{}, protected_now{}, slot_correlated{};
    unsigned pid{}, port{}, relay_slot{}, protected_slot{};
    std::uint64_t protected_query_tick{}, observed_tick{}, relay_generation_low{}, relay_generation_high{};
    std::string nonce, protection_generation, challenge;
};
inline bool hex_id(const std::string& s) {
    return s.size()==32 && s.find_first_not_of("0123456789abcdef")==std::string::npos;
}
inline bool current(const observation& o,std::uint64_t now) {
    return o.relay_ready && o.loopback && o.protected_now && o.slot_correlated &&
        o.pid && o.port>=27100 && o.port<=27999 && o.relay_slot<4 &&
        o.protected_slot==o.relay_slot && hex_id(o.nonce) && hex_id(o.protection_generation) &&
        !o.challenge.empty() && (o.relay_generation_low || o.relay_generation_high) &&
        o.protected_query_tick && now>=o.protected_query_tick && now-o.protected_query_tick<=500 &&
        now>=o.observed_tick && now-o.observed_tick<=500;
}
inline bool same(const observation& bound,const observation& now) {
    return bound.pid==now.pid && bound.port==now.port && bound.relay_slot==now.relay_slot &&
        bound.protected_slot==now.protected_slot && bound.nonce==now.nonce &&
        bound.protection_generation==now.protection_generation && bound.challenge==now.challenge &&
        bound.relay_generation_low==now.relay_generation_low && bound.relay_generation_high==now.relay_generation_high;
}
struct role_registration {
    bool present{}, incarnation{}, registered{}, voice_registered{};
    std::uint64_t roster_user{}, native_user{};
};
inline bool both_roles(bool live,const role_registration& a,const role_registration& b) {
    return live && a.present && b.present && a.incarnation && b.incarnation && a.registered && b.registered &&
        a.voice_registered && b.voice_registered && a.roster_user && b.roster_user && a.roster_user!=b.roster_user &&
        a.native_user==a.roster_user && b.native_user==b.roster_user;
}
struct arm_request {
    unsigned pid{}, slot{};
    std::uint64_t tick{};
    std::string nonce, generation, source_hash, recorder_challenge;
};
inline bool decimal(const std::string& s,std::uint64_t& n) {
    if(s.empty() || (s.size()>1 && s[0]=='0'))return false;
    n=0;for(const auto c:s){if(c<'0'||c>'9')return false;
        const auto d=static_cast<unsigned>(c-'0');
        if(n>(std::numeric_limits<std::uint64_t>::max()-d)/10)return false;
        n=n*10+d;}return true;
}
inline bool parse_request(const std::string& wire,arm_request& out,bool cancel) {
    if(wire.empty() || wire.size()>256 || wire.back()!='\n' ||
        wire.find_first_of("\r\t\0",0,3)!=std::string::npos || wire.find('\n')!=wire.size()-1)return false;
    std::istringstream in(wire);std::string version,pid,slot,tick,extra;arm_request a;
    if(!(in>>version>>pid>>a.nonce>>a.generation>>slot>>a.source_hash>>a.recorder_challenge>>tick) || in>>extra || version!=(cancel?"capturecancel1":"capturearm1"))return false;
    std::uint64_t p{},r{};
    if(!decimal(pid,p) || !p || p>std::numeric_limits<unsigned>::max() || !decimal(slot,r) || r>1 || !decimal(tick,a.tick) || !a.tick ||
        !hex_id(a.nonce) || !hex_id(a.generation) || !hex_id(a.recorder_challenge) || a.source_hash.size()!=64 ||
        a.source_hash.find_first_not_of("0123456789abcdef")!=std::string::npos)return false;
    a.pid=static_cast<unsigned>(p);a.slot=static_cast<unsigned>(r);
    const auto canonical=std::string(cancel?"capturecancel1 ":"capturearm1 ")+pid+" "+a.nonce+" "+a.generation+" "+slot+" "+a.source_hash+" "+a.recorder_challenge+" "+tick+"\n";
    if(wire!=canonical)return false;
    out=std::move(a);return true;
}
inline bool parse_arm(const std::string& wire,arm_request& out){return parse_request(wire,out,false);}
inline bool parse_cancel(const std::string& wire,arm_request& out){return parse_request(wire,out,true);}
inline bool admit_cancel(const arm_request& a,const observation& bound,const std::string& hash,const std::string& recorder,std::uint64_t now) {
    return a.pid==bound.pid && a.slot==bound.relay_slot && a.nonce==bound.nonce && a.generation==bound.protection_generation &&
        a.source_hash==hash && hex_id(recorder) && a.recorder_challenge==recorder && a.tick && now>=a.tick && now-a.tick<=500;
}
inline bool admit_arm(const arm_request& a,const observation& o,const std::string& hash,std::uint64_t now) {
    return current(o,now) && a.pid==o.pid && a.slot==o.relay_slot && a.nonce==o.nonce && a.generation==o.protection_generation &&
        a.source_hash==hash && hex_id(a.recorder_challenge) && a.tick && now>=a.tick && now-a.tick<=500;
}
}
