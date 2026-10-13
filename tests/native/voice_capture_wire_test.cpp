#include "voice_capture_wire.hpp"
#include <cassert>
int main(){
    using namespace voice_capture_wire;const std::string n(32,'a'),g(32,'b');query q;reply r;
    const auto legacy=n+" 1000";assert(request(n,1000,false)==legacy);
    assert(parse_query(legacy,false,q) && !q.capture_version);
    const auto oldreply=n+" 1000 "+g+" 1 cp_zmb";assert(response(q,g,true,"cp_zmb",1)==oldreply);
    assert(parse_reply(oldreply,false,n,r) && r.safe && !r.capture_version);
    const auto v=request(n,1000,true);assert(!parse_query(v,false,q));assert(parse_query(v,true,q) && q.capture_version);
    const auto newreply=response(q,g,true,"cp_zmb",1);assert(parse_reply(newreply,true,n,r) && r.slot==1 && r.safe);
    assert(!parse_reply(newreply,false,n,r));assert(!parse_reply(oldreply,true,n,r));
    assert(!parse_reply(response(q,g,true,"cp_zmb",4),true,n,r));assert(parse_reply(response(q,g,false,"cp_zmb",4),true,n,r));
    assert(!parse_reply(newreply+" extra",true,n,r));assert(!parse_query(v+" extra",true,q));
    assert(!parse_reply(newreply,true,std::string(32,'c'),r));assert(!parse_query("capture2 "+n+" 1000",true,q));
}
