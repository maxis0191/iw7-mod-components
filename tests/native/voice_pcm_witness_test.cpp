#include "voice_pcm_witness.hpp"
#include <cassert>
#include <iostream>

int main() {
    using namespace voice_pcm_witness;
    const scope valid{123,1,0,std::string(32,'a'),std::string(32,'b'),std::string(32,'c'),1000,16000};
    const speaker remote{0,42,1,2,1,0};
    const frame full{4,{100,-200,300,-400},8};
    buffer good(valid);
    assert(!good.failed() && !good.speaker_identity());
    assert(good.append(remote,full,1000,true));
    auto next=remote; next.sequence=2; next.frame_index=1;
    assert(good.append(next,frame{4,{1,2,3,4},4},1001,true));
    assert(good.append(next,frame{4,{5,6,7,8},0},1001,true));
    assert(good.frames()==3 && good.decoded_bytes()==24 && good.enqueued_bytes()==12 && good.truncated_frames()==2);
    assert((good.submitted()==std::vector<std::int16_t>{100,-200,300,-400,1,2}));
    assert(good.decoded()[11]==8 && good.speaker_identity()->user==42);
    // The input frame can disappear/change without altering retained evidence.
    auto temporary=full; buffer copied(valid);
    assert(copied.append(remote,temporary,1000,true)); temporary.decoded[0]=999;
    assert(copied.decoded()[0]==100 && copied.submitted()[0]==100);
    buffer revoked(valid);
    assert(revoked.append(remote,full,1000,true));
    const auto retained_decoded=revoked.decoded();
    const auto retained_submitted=revoked.submitted();
    revoked.invalidate(); revoked.invalidate();
    assert(revoked.failed() && revoked.frames()==1 && revoked.speaker_identity()->user==remote.user);
    assert(!revoked.append(remote,full,1001,true));
    assert(revoked.decoded()==retained_decoded && revoked.submitted()==retained_submitted &&
        revoked.decoded_bytes()==8 && revoked.enqueued_bytes()==8 && revoked.truncated_frames()==0);
    const auto invalid_scope=[&](scope s){buffer b(s);assert(b.failed());assert(!b.append(remote,full,1000,true));};
    auto s=valid; s.pid=0; invalid_scope(s);
    s=valid; s.receiver_slot=0; invalid_scope(s);
    s=valid; s.sender_slot=2; invalid_scope(s);
    s=valid; s.nonce=std::string(32,'0'); invalid_scope(s);
    s=valid; s.generation=std::string(32,'A'); invalid_scope(s);
    s=valid; s.challenge="abc"; invalid_scope(s);
    s=valid; s.admitted_tick=0; invalid_scope(s);
    s=valid; s.deadline_tick=1000; invalid_scope(s);
    s=valid; s.deadline_tick=16001; invalid_scope(s);
    const auto invalid_frame=[&](frame f){buffer b(valid);assert(!b.append(remote,f,1000,true));assert(b.failed() && b.frames()==0 && b.decoded().empty());assert(!b.append(remote,full,1001,true));};
    invalid_frame(frame{0,{},0}); invalid_frame(frame{4097,std::vector<std::int16_t>(4097),0});
    invalid_frame(frame{4,{1,2,3},6}); invalid_frame(frame{4,{1,2,3,4},-2});
    invalid_frame(frame{4,{1,2,3,4},3}); invalid_frame(frame{4,{1,2,3,4},10});
    for(unsigned change=0;change<5;++change){
        buffer b(valid);assert(b.append(remote,full,1000,true));auto foreign=remote;
        if(change==0)foreign.slot=1;if(change==1)foreign.user=43;
        if(change==2)foreign.epoch_low=2;if(change==3)foreign.epoch_high=3;
        if(change==4){foreign.epoch_low=0;foreign.epoch_high=0;}
        assert(!b.append(foreign,full,1001,true) && b.failed() && b.frames()==1 && b.decoded_bytes()==8);
    }
    auto absent=remote;absent.user=0;buffer no_user(valid);assert(!no_user.append(absent,full,1000,true));
    for(const auto tick:{999ULL,16000ULL,16001ULL}){buffer b(valid);assert(!b.append(remote,full,tick,true) && b.failed());}
    buffer stale(valid);assert(!stale.append(remote,full,1000,false));
    buffer reversed(valid);assert(reversed.append(remote,full,1002,true));assert(!reversed.append(remote,full,1001,true));
    // Fill the exact byte bound; the next frame must fail without partial writes.
    buffer bounded(valid);frame block{4096,std::vector<std::int16_t>(4096,17),8192};
    for(unsigned i=0;i<32;++i)assert(bounded.append(remote,block,1000+i,true));
    assert(bounded.decoded_bytes()==buffer::byte_limit && bounded.enqueued_bytes()==buffer::byte_limit);
    assert(!bounded.append(remote,full,1033,true) && bounded.frames()==32 && bounded.submitted().size()==131072);
    buffer zero_submit(valid);block.enqueued_bytes=0;
    for(unsigned i=0;i<32;++i)assert(zero_submit.append(remote,block,1000+i,true));
    assert(zero_submit.submitted().empty() && zero_submit.truncated_frames()==32);
    assert(!zero_submit.append(remote,full,1033,true) && zero_submit.decoded_bytes()==buffer::byte_limit);
    std::cout << "PASS bounded native PCM witness identity, freshness, truncation and retained copies\n";
}
