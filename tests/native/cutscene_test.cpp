#include "../../src/native/cutscene_policy.hpp"
#include <cassert>
#include <iostream>
using iw7::cutscene::ballot;
void hold(ballot& b,unsigned slot,unsigned key,std::uint64_t start) {
    b.input(slot,0,start);b.input(slot,key,start+1);b.input(slot,key,start+2000);
    assert(!b.players[slot].voted);b.input(slot,key,start+2001);
}
int main(){
    ballot eight;
    for (unsigned slot=0; slot<8; ++slot) eight.roster(slot,std::to_string(slot));
    for (unsigned slot=0; slot<7; ++slot) hold(eight,slot,1,100);
    assert(eight.total()==8 && eight.votes()==7 && !eight.unanimous());
    hold(eight,7,4,100);assert(eight.unanimous());
    eight.roster(7,"replacement");assert(!eight.unanimous());
    eight.roster(7,"");assert(eight.unanimous());
    eight.roster(17,"last");assert(eight.total()==8 && !eight.unanimous());
    eight.roster(18,"invalid");assert(eight.total()==8);
    assert(iw7::cutscene::hud_ballot(4,4)==36);
    assert(iw7::cutscene::hud_ballot(7,8)==0);
    for(unsigned key:{1u,2u,4u}){
        ballot b;b.roster(0,"one");
        b.input(0,key,1);b.input(0,key,5000);assert(!b.unanimous()); // Held before window needs release.
        hold(b,0,key,6000);assert(b.unanimous());
        b.input(0,0,10000);b.input(0,key,12000);assert(b.votes()==1);
    }
    ballot b;b.roster(0,"one");b.roster(1,"two");
    hold(b,0,1,10);assert(b.votes()==1 && b.total()==2 && !b.unanimous());
    b.roster(2,"three");assert(b.total()==3 && !b.unanimous());
    hold(b,1,2,3000);assert(b.votes()==2 && !b.unanimous());
    b.roster(2,"");assert(b.unanimous());
    b.roster(1,"replacement");assert(b.votes()==1 && !b.unanimous());
    b.input(1,0,6000);b.input(1,1,6001);b.input(1,1,7900);b.input(1,0,7901);
    b.input(1,2,7902);b.input(1,2,9901);assert(!b.unanimous());b.input(1,2,9902);assert(b.unanimous());
    b.roster(0,"");b.roster(1,"");assert(!b.unanimous());
    const auto code=iw7::cutscene::wait_thunk(0x1234,0x5678);
    assert(code[0]==0x1b && code[1]==0x34 && code[2]==0x12 && code[3]==0x69);
    assert(code[4]==0x1a && code[5]==0x78 && code[6]==0x56);
    assert(7+3+code[8]==19); // False -> redirect sentinel, not End.
    assert(16+3-code[17]==4); // Retry -> pending0, never begin again.
    assert(code[15]==0x79 && code[19]==0x34);
    std::cout<<"PASS cutscene: three keys, continuous 2s, fresh release, unique votes, roster/reconnect, thunk stack/control flow\n";
}
