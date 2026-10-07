#include "voice_test_binding.hpp"
#include <cassert>
int main() {
    voice_test_binding::observation o{true,true,true,true,123,27116,1,1,1000,1100,1,2,
        std::string(32,'a'),std::string(32,'b'),"challenge"};
    using voice_test_binding::current;using voice_test_binding::same;
    assert(current(o,1500));assert(!current(o,1501));assert(!current(o,999));
    auto changed=o;changed.slot_correlated=false;assert(!current(changed,1100));
    changed=o;changed.port=27016;assert(!current(changed,1100));assert(!same(o,changed));
    changed=o;changed.protected_slot=0;assert(!current(changed,1100));
    changed=o;changed.relay_generation_low=3;assert(current(changed,1100));assert(!same(o,changed));
    changed=o;changed.protection_generation=std::string(32,'c');assert(!same(o,changed));
    changed=o;changed.nonce=std::string(32,'d');assert(!same(o,changed));
    changed=o;changed.pid=124;assert(!same(o,changed));
    changed=o;changed.relay_ready=false;assert(!current(changed,1100));
    changed=o;changed.protected_now=false;assert(!current(changed,1100));
    using voice_test_binding::parse_arm;using voice_test_binding::admit_arm;
    const std::string hash(64,'e');
    const auto wire=std::string("capturearm1 123 ")+o.nonce+" "+o.protection_generation+" 1 "+hash+" "+std::string(32,'f')+" 1000\n";
    voice_test_binding::arm_request request;
    assert(parse_arm(wire,request));assert(admit_arm(request,o,hash,1500));
    assert(!admit_arm(request,o,hash,1501));assert(!admit_arm(request,o,hash,999));
    assert(!admit_arm(request,o,std::string(64,'a'),1100));
    auto bad=request;bad.pid=124;assert(!admit_arm(bad,o,hash,1100));
    bad=request;bad.slot=0;assert(!admit_arm(bad,o,hash,1100));
    bad=request;bad.nonce=std::string(32,'c');assert(!admit_arm(bad,o,hash,1100));
    bad=request;bad.generation=std::string(32,'c');assert(!admit_arm(bad,o,hash,1100));
    assert(!parse_arm(wire.substr(0,wire.size()-1),request));
    assert(!parse_arm(wire+"x",request));assert(!parse_arm(wire+"\n",request));
    assert(!parse_arm(std::string(" ")+wire,request));
    auto malformed=wire;malformed.replace(12,3,"0123");assert(!parse_arm(malformed,request));
    malformed=wire;malformed.replace(12,3,"4294967296");assert(!parse_arm(malformed,request));
    malformed=wire;malformed.replace(malformed.size()-5,4,"18446744073709551616");assert(!parse_arm(malformed,request));
    malformed=wire;malformed[0]='C';assert(!parse_arm(malformed,request));
    malformed=wire;malformed[20]='\0';assert(!parse_arm(malformed,request));
    malformed=wire;malformed[11]='\t';assert(!parse_arm(malformed,request));
    assert(!parse_arm(std::string(257,'a'),request));
    voice_test_binding::role_registration a{true,true,true,true,101,101}, b{true,true,true,true,102,102};
    assert(voice_test_binding::both_roles(true,a,b));
    assert(!voice_test_binding::both_roles(false,a,b));
    auto foreign=b;foreign.native_user=103;assert(!voice_test_binding::both_roles(true,a,foreign));
    foreign=a;foreign.native_user=103;assert(!voice_test_binding::both_roles(true,foreign,b));
    foreign=b;foreign.incarnation=false;assert(!voice_test_binding::both_roles(true,a,foreign));
    foreign=b;foreign.voice_registered=false;assert(!voice_test_binding::both_roles(true,a,foreign));
    assert(!voice_test_binding::both_roles(true,a,a));
    const auto cancel_wire=std::string("capturecancel1")+wire.substr(std::string("capturearm1").size());
    assert(!parse_arm(cancel_wire,request));assert(!voice_test_binding::parse_cancel(wire,request));
    assert(voice_test_binding::parse_cancel(cancel_wire,request));
    auto stale_bound=o;stale_bound.protected_now=false;stale_bound.relay_ready=false;
    assert(voice_test_binding::admit_cancel(request,stale_bound,hash,std::string(32,'f'),1500));
    assert(!voice_test_binding::admit_cancel(request,stale_bound,hash,std::string(32,'e'),1100));
    assert(!voice_test_binding::admit_cancel(request,stale_bound,hash,std::string(32,'f'),1501));
    assert(!voice_test_binding::admit_cancel(request,stale_bound,hash,std::string(32,'f'),999));
    assert(!voice_test_binding::admit_cancel(request,stale_bound,hash,"",1100));
    bad=request;bad.pid++;assert(!voice_test_binding::admit_cancel(bad,stale_bound,hash,std::string(32,'f'),1100));
    bad=request;bad.generation=std::string(32,'c');assert(!voice_test_binding::admit_cancel(bad,stale_bound,hash,std::string(32,'f'),1100));
}
