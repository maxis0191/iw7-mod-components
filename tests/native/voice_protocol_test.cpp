#include "../../src/native/paris_voice_protocol.hpp"
#include "../../src/native/paris_test_safety.hpp"
#include <cstdlib>
#include <iostream>
#include <random>
#include <stdexcept>

namespace w = paris_voice::protocol;
void check(bool ok, const char* what) { if (!ok) throw std::runtime_error(what); }
int main()
{
    using namespace paris_test_fixture;
    const kick_context safe{true,true,true,true,true,true,true,true,true,true};
    check(allow_inactivity_exception(safe,"EXE_PLAYERKICKED_INACTIVE"), "protected fixture inactivity still kicks");
    for (int i=0; i<10; ++i)
    {
        auto unsafe=safe;
        bool* gates[]={&unsafe.dedicated,&unsafe.fixture,&unsafe.zombies,&unsafe.private_access,&unsafe.loopback,
            &unsafe.bound_identity,&unsafe.connected,&unsafe.godmode,&unsafe.cheats_disabled,&unsafe.native_inactivity_disabled};
        *gates[i]=false;
        check(!allow_inactivity_exception(unsafe,"EXE_PLAYERKICKED_INACTIVE"),"unprotected/remote/reused-slot inactivity exception");
    }
    check(!allow_inactivity_exception(safe,"EXE_PLAYERKICKED") && !allow_inactivity_exception(safe,"GAME_DROPPEDFORINACTIVITY") &&
        !allow_inactivity_exception(safe,"EXE_PLAYERKICKED_INACTIVE "),"unrelated kick was bypassed");
    client_test_protection client{true,true,42,27116,27116,1000,1010,std::string(32,'a'),std::string(32,'b'),"connection-challenge","cp_zmb"};
    check(client_protection_current(client,1010) && client_protection_current(client,1500),"fresh client snapshot rejected");
    check(!client_protection_current(client,1501) && !client_protection_current(client,1009),"stale/future client snapshot accepted");
    check(!client_protection_current({},1010),"empty client protection accepted");
    for (int i=0; i<12; ++i)
    {
        auto invalid=client;
        switch(i)
        {
        case 0: invalid.protected_now=false; break;
        case 1: invalid.current_loopback=false; break;
        case 2: invalid.pid=0; break;
        case 3: invalid.expected_port=27016; break;
        case 4: invalid.expected_port=28000; break;
        case 5: invalid.port=27117; break;
        case 6: invalid.query_tick=0; break;
        case 7: invalid.observed_tick=999; break;
        case 8: invalid.nonce[0]='z'; break;
        case 9: invalid.generation.pop_back(); break;
        case 10: invalid.challenge.clear(); break;
        case 11: invalid.map="cp_frontend"; break;
        }
        check(!client_protection_current(invalid,1010),"invalid client protection identity/scope accepted");
    }
    for(const auto* map : {"cp_zmb","cp_rave","cp_disco","cp_town","cp_final"})
    {auto current=client;current.map=map;check(client_protection_current(current,1010),"supported CP map rejected");}
    w::packet p, decoded;
    p.type = w::kind::hello; p.token = 0xFEDCBA9876543210ull;
    check(w::decode(w::encode(p), decoded) && decoded.token == p.token, "hello roundtrip");
    p.type = w::kind::ready; p.challenge = 123; p.speaker = 17;
    check(w::decode(w::encode(p), decoded) && decoded.challenge == 123 && decoded.speaker == 17, "ready roundtrip");
    p.type = w::kind::audio; p.sequence = 0xFFFFFFFFu;
    p.frames = {std::string("\0\xff\n\0", 4), std::string(254, '\xff')};
    const auto bytes = w::encode(p);
    check(w::decode(bytes, decoded) && decoded.frames == p.frames && decoded.sequence == p.sequence, "binary audio roundtrip");
    p.type = w::kind::probe;
    check(w::decode(w::encode(p), decoded) && decoded.type == w::kind::probe && decoded.frames == p.frames, "synthetic calibration roundtrip");
    p.type = w::kind::audio;
    for (std::size_t i = 0; i < bytes.size(); ++i) check(!w::decode(std::string_view(bytes).substr(0, i), decoded), "truncated packet accepted");
    check(!w::decode(bytes + 'x', decoded), "trailing byte accepted");
    auto bad = bytes; bad[2] = 2; check(!w::decode(bad, decoded), "wrong protocol accepted");
    bad = bytes; bad[3] = 9; check(!w::decode(bad, decoded), "unknown kind accepted");
    bad = bytes; bad[16] = 18; check(!w::decode(bad, decoded), "invalid speaker accepted");
    bad = bytes; bad[17] = 11; check(!w::decode(bad, decoded), "excess frames accepted");
    bad = bytes; bad[18] = 0; check(!w::decode(bad, decoded), "zero frame accepted");
    p.frames = {std::string(255, 'x')}; check(w::encode(p).empty(), "oversized frame encoded");
    p.frames.assign(10, std::string(254, 'x')); check(w::encode(p).empty(), "oversized datagram encoded");
    p.token = 0; check(w::encode(p).empty(), "zero capability encoded");
    w::replay_window replay;
    check(replay.accept(0xFFFFFFFEu) && replay.accept(0xFFFFFFFFu) && replay.accept(0) && replay.accept(1), "sequence wrap rejected");
    check(!replay.accept(1) && !replay.accept(0) && !replay.accept(0x80000001u), "replayed/backwards sequence accepted");
    w::rate_limit rate;
    for (int i = 0; i < 10; ++i) check(rate.accept(10, 1200, 1000), "initial bounded burst rejected");
    check(!rate.accept(1, 1, 1000), "frame flood accepted");
    check(rate.accept(60, 1200, 2000), "normal frame rate rejected");
    check(!rate.accept(1, 1, 2000), "sustained frame flood accepted");
    w::rate_limit byte_rate;
    check(byte_rate.accept(1, 24000, 1000) && !byte_rate.accept(1, 1, 1000), "byte flood accepted");
    check(byte_rate.accept(1, 16000, 2000), "byte refill failed");
    std::mt19937 rng(0x495737);
    unsigned accepted = 0;
    for (unsigned i = 0; i < 200000; ++i)
    {
        std::string fuzz(rng() % 1500, '\0');
        for (auto& c : fuzz) c = static_cast<char>(rng());
        if (i % 2 == 0 && fuzz.size() >= 4) { fuzz[0] = 'P'; fuzz[1] = 'V'; fuzz[2] = 1; fuzz[3] = static_cast<char>(1 + rng() % 3); }
        if (w::decode(fuzz, decoded)) { ++accepted; check(w::encode(decoded) == fuzz, "accepted packet is not canonical"); }
    }
    std::cout << "PASS: binary roundtrips, every truncation, limits, replay/wrap, frame/byte rate limits, 200000 seeded malformed datagrams (" << accepted << " canonical).\n";
}
