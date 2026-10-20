#include "../../src/native/paris_capacity_watch.hpp"
#include "../../src/native/paris_agent_capacity.hpp"
#include <cassert>
#include <thread>
#include <string>
#include <vector>
#include <random>
#include <cstring>
#ifdef _WIN32
#include <Windows.h>
#endif

static void archive_ranges() {
    using namespace paris_agent_capacity;
    using namespace animation_archive;
    std::array<unsigned char,0x400> legacy{},corrected{};
    for(unsigned slot=0;slot<characters;++slot) {
        legacy[flags+slot]=1;
        corrected[flags+slot]=1;
    }
    std::uint64_t damaged{},intact{};
    std::memcpy(&damaged,legacy.data()+0x40,8);
    std::memcpy(&intact,corrected.data()+pointers,8);
    assert(damaged==0x0101010101010101ull && intact==0);
    // Reproduce the exact two-byte corruption seen in the owner's pointer.
    legacy.fill(0);legacy[flags+48]=legacy[flags+49]=1;
    std::memcpy(&damaged,legacy.data()+0x40,8);
    assert(damaged==0x10100000000ull);
    for(unsigned slot=0;slot<characters;++slot) {
        assert(slot*2+2<=controller_records);
        assert(controller_records+slot*0x48+0x48<=controller_size);
        assert(slot*4+4<=xanim_counts);
        assert(xanim_counts+slot*4+4<=xanim_counter);
        assert(flags+slot<pointers);
        assert(pointers+slot*8+8<=active);
    }
    assert(xanim_base==controller_base+controller_size);
    assert(restore==frame_base+frames*frame_size);
    assert(rewind>=restore+0x12010 && rewind+active<object_size);
}

#ifdef _WIN32
// Execute the actual replacement instructions with guarded synthetic buffers.
// No engine process or retail executable is loaded by this regression test.
static void archive_instructions() {
    using namespace paris_agent_capacity;
    using namespace animation_archive;
    const auto run=[](const std::vector<unsigned char>& code,const void* id,const void* frame,void* output) {
        void* memory=VirtualAlloc(nullptr,code.size(),MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
        assert(memory);std::memcpy(memory,code.data(),code.size());
        DWORD previous{};assert(VirtualProtect(memory,code.size(),PAGE_EXECUTE_READ,&previous));
        assert(FlushInstructionCache(GetCurrentProcess(),memory,code.size()));
        reinterpret_cast<void(*)(const void*,const void*,void*)>(memory)(id,frame,output);
        assert(VirtualFree(memory,0,MEM_RELEASE));
    };
    const auto copy_code=[](const auto& body,bool next) {
        std::vector<unsigned char> code={0x53,0x57,0x41,0x56,0x48,0x81,0xec,0x80,0,0,0,
            0x49,0x89,0xce,0x48,0x89,0xd7,0x48,0x89,0xd3,0x4c,0x89,0x44,0x24,0x70};
        code.insert(code.end(),body.begin(),body.end()-(next?5:0));
        const unsigned char tail[]={0xf2,0x0f,0x11,0x40,0x40,0x48,0x81,0xc4,0x80,0,0,0,0x41,0x5e,0x5f,0x5b,0xc3};
        code.insert(code.end(),std::begin(tail),std::end(tail));return code;
    };
    std::vector<unsigned char> frame(controller_size+16);
    for(std::size_t i=0;i<frame.size();++i)frame[i]=static_cast<unsigned char>((i*29)^(i>>8));
    const auto previous=copy_code(previous_after,false),next=copy_code(next_after,true);
    const auto old_previous=copy_code(previous_before,false),old_next=copy_code(next_before,true);
    for(int slot=0;slot<static_cast<int>(characters);++slot) {
        for(const auto* code:{&previous,&next,&old_previous,&old_next}) {
            std::array<unsigned char,0x58> output{};output.fill(0xA7);
            run(*code,&slot,frame.data(),output.data()+8);
            for(unsigned i=0;i<8;++i)assert(output[i]==0xA7 && output[0x50+i]==0xA7);
            const bool correct=std::memcmp(output.data()+8,frame.data()+controller_records+slot*0x48,0x48)==0;
            assert(correct==(code==&previous || code==&next));
        }
    }
    // The two-frame branch computes both bases, retaining its existing output
    // and interpolation arguments. Test the real bytes without its engine call.
    std::vector<unsigned char> blend={0x53,0x55,0x57,0x41,0x56,0x48,0x81,0xec,0x80,0,0,0,
        0x49,0x89,0xce,0x48,0x89,0xd7,0x48,0x89,0xd3,0x4c,0x89,0x44,0x24,0x70,
        0x4c,0x89,0xc5,0x49,0x63,0x06};
    blend.insert(blend.end(),blend_after.begin(),blend_after.end());
    const unsigned char tail[]={0x49,0x89,0x09,0x49,0x89,0x51,0x08,0xf3,0x41,0x0f,0x11,0x51,0x10,
        0x48,0x81,0xc4,0x80,0,0,0,0x41,0x5e,0x5f,0x5d,0x5b,0xc3};
    blend.insert(blend.end(),std::begin(tail),std::end(tail));
    for(int slot=0;slot<static_cast<int>(characters);++slot) {
        std::array<std::uintptr_t,3> output{};output[2]=0x12345678;
        run(blend,&slot,frame.data(),output.data());
        assert(output[0]==reinterpret_cast<std::uintptr_t>(frame.data()+controller_records+slot*0x48));
        assert(output[1]==output[0] && output[2]==0x12345678);
    }
}
#endif

// Independent regression model of the engine's agent-state record framing.
// The actual runtime keeps the engine codec and changes its five index widths.
struct agent_record {
    unsigned id;
    bool removed;
    unsigned payload;
    bool operator==(const agent_record& other) const {
        return id==other.id && removed==other.removed && payload==other.payload;
    }
};
static std::vector<agent_record> agent_wire_roundtrip(const std::vector<agent_record>& input,unsigned width,bool force_explicit=false) {
    std::vector<bool> bits;
    const auto write=[&](unsigned v,unsigned count){for(unsigned i=0;i<count;++i)bits.push_back((v>>i)&1);};
    int previous=-1;
    for(const auto& row:input){
        write(1,1);
        const bool predicted=!(force_explicit && row.id>=64) && static_cast<int>(row.id)==previous+1;
        write(predicted,1);
        if(!predicted)write(row.id,width);
        previous=static_cast<int>(row.id);
        write(row.removed,1);
        if(!row.removed)write(row.payload,16);
    }
    write(0,1);
    std::size_t cursor{};
    const auto read=[&](unsigned count){unsigned value{};for(unsigned i=0;i<count;++i){assert(cursor<bits.size());value|=static_cast<unsigned>(bits[cursor++])<<i;}return value;};
    std::vector<agent_record> output;previous=-1;
    while(read(1)){
        const unsigned id=read(1)?static_cast<unsigned>(previous+1):read(width);
        previous=static_cast<int>(id);
        const bool removed=read(1)!=0;
        output.push_back({id,removed,removed?0:read(16)});
    }
    assert(cursor==bits.size());return output;
}
int main() {
    archive_ranges();
#ifdef _WIN32
    archive_instructions();
#endif
    {
        using namespace paris_agent_capacity;
        static_assert(ordinary == 48 && special_reserve == 16 && agents == 64);
        static_assert(server_size >= 0x46B8 + characters * 0x2CA0 + players * 0x70);
        static_assert(client_size >= client_flags + characters);
        for (unsigned slot=0;slot<characters;++slot) assert((slot & ((1u<<character_bits)-1))==slot);
        assert((64u & ((1u<<6)-1))==0); // Reproduce the observed legacy alias.
        assert(compatible_wire(false,"") && compatible_wire(false,"24"));
        assert(!compatible_wire(false,"64-v2") && !compatible_wire(false,"unknown"));
        assert(compatible_wire(true,"64-v2"));
        assert(!compatible_wire(true,"64-v1")); // Refuse the earlier incomplete codec.
        assert(!compatible_wire(true,"") && !compatible_wire(true,"24") && !compatible_wire(true,"unknown"));
        std::int32_t delta{};
        assert(relative32(0x180000000,0x140000000,delta) && delta == 0x40000000);
        assert(relative32(0x140000000,0x180000000,delta) && delta == -0x40000000);
        assert(relative32(0x180000000,0x100000000,delta) == false);
        assert(relative32(0x100000000,0x180000000,delta) && delta == std::numeric_limits<std::int32_t>::min());
        assert(!relative32(0x100000000,0x180000001,delta));
        const std::vector<agent_record> consecutive{{62,false,9},{63,false,10},{64,false,11},{65,true,0}};
        const std::vector<agent_record> sparse{{62,false,9},{64,false,11},{81,true,0}};
        assert(agent_wire_roundtrip(consecutive,6)==consecutive); // Predictor masks the defect.
        assert(agent_wire_roundtrip(sparse,6)!=sparse);
        assert(agent_wire_roundtrip(sparse,character_bits)==sparse);
        assert(agent_wire_roundtrip(consecutive,character_bits,true)==consecutive);
        assert(agent_wire_roundtrip(consecutive,6,true)!=consecutive);
        std::mt19937 random(0x48A6E17u);
        for(unsigned run=0;run<20000;++run){
            std::vector<agent_record> records;
            for(unsigned i=0;i<32;++i){const bool removed=(random()&3)==0;records.push_back({static_cast<unsigned>(random()%characters),removed,removed?0u:static_cast<unsigned>(random()&0xffffu)});}
            assert(agent_wire_roundtrip(records,character_bits)==records);
            assert(agent_wire_roundtrip(records,character_bits,true)==records);
        }
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
