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
    std::atomic<unsigned> ticket{2};
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
