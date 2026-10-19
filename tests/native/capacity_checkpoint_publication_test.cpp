#define NOMINMAX
#include <Windows.h>
#include <atomic>
#include <cassert>
#include <thread>
#include <cstdio>
#include "../../src/native/paris_capacity_watch.hpp"

// Deterministic interleaving: target acknowledges the published ticket before
// the helper's final notification finishes. A closer must refuse that window.
int main() {
    using namespace paris_capacity_watch;
    assert(checkpoint_operation(phase::empty,false)==1);
    assert(checkpoint_operation(phase::data,false)==0);
    assert(checkpoint_operation(phase::data,true)==2);
    assert(checkpoint_operation(phase::disarming,true)==2);
    assert(checkpoint_operation(phase::failed,true)==2);
    // A completed target must not continuously queue new close tickets and
    // starve the async helper/VEH cleanup after a real map restart.
    for(unsigned tick=0;tick<1000;++tick) {
        assert(checkpoint_operation(phase::closed,true)==0);
        assert(checkpoint_operation(phase::closed,false)==0);
    }
    std::atomic<unsigned> ticket{2};
    std::atomic<unsigned> exited_ticket{3};
    std::atomic<bool> exited_inflight{true};
    acknowledge_exited_target_ticket(exited_ticket,exited_inflight);
    assert(exited_ticket.load()==3);
    exited_inflight.store(false);
    acknowledge_exited_target_ticket(exited_ticket,exited_inflight);
    assert(exited_ticket.load()==0);
    exited_ticket.store(2);
    acknowledge_exited_target_ticket(exited_ticket,exited_inflight);
    assert(exited_ticket.load()==2);
    exited_ticket.store(1);
    acknowledge_exited_target_ticket(exited_ticket,exited_inflight);
    assert(exited_ticket.load()==0);
    std::atomic<bool> inflight{true};
    const auto notify_entered=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    const auto notify_continue=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    const auto checkpoint_done=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    assert(notify_entered && notify_continue && checkpoint_done);
    std::thread publisher([&] {
        paris_capacity_watch::publish_checkpoint_completion(ticket,inflight,[&] {
            assert(SetEvent(notify_entered));
            assert(WaitForSingleObject(notify_continue,1000)==WAIT_OBJECT_0);
            assert(SetEvent(checkpoint_done));
        });
    });
    assert(WaitForSingleObject(notify_entered,1000)==WAIT_OBJECT_0);
    assert(ticket.load(std::memory_order_acquire)==3);
    acknowledge_exited_target_ticket(ticket,inflight);
    assert(ticket.load(std::memory_order_acquire)==3);
    ticket.store(0,std::memory_order_release); // Target's actual acknowledgement.
    const bool closure_allowed=ticket.load()==0 && !inflight.load(std::memory_order_acquire);
    assert(!closure_allowed);
    assert(WaitForSingleObject(checkpoint_done,0)==WAIT_TIMEOUT);
    assert(SetEvent(notify_continue));
    publisher.join();
    assert(ticket.load()==0 && !inflight.load(std::memory_order_acquire));
    assert(WaitForSingleObject(checkpoint_done,0)==WAIT_OBJECT_0);
    assert(CloseHandle(checkpoint_done));
    assert(CloseHandle(notify_entered));
    assert(CloseHandle(notify_continue));
    std::puts("PASS target acknowledgement cannot close the helper's final notification handle.");
}
