#include "../../src/native/paris_capacity_watch.hpp"
#include "../../src/native/paris_agent_capacity.hpp"
#include <cassert>
#include <thread>
#include <string>
#include <vector>
int main() {
    {
        using namespace paris_agent_capacity;
        static_assert(ordinary == 48 && special_reserve == 16 && agents == 64);
        static_assert(server_size >= 0x46B8 + characters * 0x2CA0 + players * 0x70);
        static_assert(client_size >= client_flags + characters);
        for (unsigned slot=0;slot<characters;++slot) assert((slot & ((1u<<character_bits)-1))==slot);
        assert((64u & ((1u<<6)-1))==0); // Reproduce the observed legacy alias.
        assert(compatible_wire(false,"") && compatible_wire(false,"24"));
        assert(!compatible_wire(false,"64-v1") && !compatible_wire(false,"unknown"));
        assert(compatible_wire(true,"64-v1"));
        assert(!compatible_wire(true,"") && !compatible_wire(true,"24") && !compatible_wire(true,"unknown"));
        std::int32_t delta{};
        assert(relative32(0x180000000,0x140000000,delta) && delta == 0x40000000);
        assert(relative32(0x140000000,0x180000000,delta) && delta == -0x40000000);
        assert(relative32(0x180000000,0x100000000,delta) == false);
        assert(relative32(0x100000000,0x180000000,delta) && delta == std::numeric_limits<std::int32_t>::min());
        assert(!relative32(0x100000000,0x180000001,delta));
    }
    using namespace paris_capacity_watch;
    assert(valid_nonce("0123456789abcdef"));
    assert(!valid_nonce("short") && !valid_nonce("0123456789abc;ef"));
    assert(!valid_nonce(std::string(65, 'a')));
    assert(!elapsed(99, 100, 10)); assert(!elapsed(109, 100, 10)); assert(elapsed(110, 100, 10));
    static_assert((field_b8 & 7) == 0 && (field_c0 & 7) == 0);
    static_assert((canary_dr7 & 0xf) == 1 && (data_dr7 & 0xf) == 5);
    assert(clear_debug_state(0,0,0,0,0xffff0ff0,0x400,0));
    assert(!clear_debug_state(1,0,0,0,0,0,0)); // Never overwrite inactive foreign slot either.
    assert(!clear_debug_state(0,0,0,0,1,0,0));
    assert(!clear_debug_state(0,0,0,0,0,4,0));
    assert(!clear_debug_state(0,0,0,0,0,0,0x100));
    assert(matching_canary(1,0x1000,canary_dr7|0x400,0x1000,0x400));
    assert(!matching_canary(2,0x1000,canary_dr7,0x1000,0));
    assert(!matching_canary(1,0x2000,canary_dr7,0x1000,0));
    assert(!matching_canary(1,0x1000,data_dr7,0x1000,0));
    write_history h;
    h.observe(1, 7, 0); assert(!h.first_nonzero && !h.zero_seen); // Existing nonzero is not publication proof.
    h.observe(1, 0, 0); assert(h.zero_seen == 1); // Only triggered field counts as zero witnessed.
    h.observe(2, 0, 0); assert(h.zero_seen == 3);
    h.observe(1, 9, 4); assert(h.first_nonzero == 1); // Untriggered C0 value cannot earn C0 credit.
    h.observe(2, 9, 4); assert(h.first_nonzero == 3);
    fixed_ring<observation> ring;
    std::vector<std::thread> threads;
    for (unsigned t=0;t<4;++t) threads.emplace_back([&,t] {
        for (unsigned i=0;i<32;++i) { observation e{}; e.tid=t; e.rip=100+i; ring.append(e); }
    });
    for (auto& t : threads) t.join();
    assert(ring.reserved() == max_events);
    for (unsigned i=0;i<max_events;++i) { const auto* e=ring.get(i); assert(e && e->tid < 4 && e->rip >= 100); }
    assert(!ring.append({}) && !ring.get(max_events));
}
