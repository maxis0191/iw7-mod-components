#include <std_include.hpp>
#include "paris_agent_capacity.hpp"
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "scheduler.hpp"
#include "console/console.hpp"
#include <utils/flags.hpp>
#include <utils/hook.hpp>
#include <shellapi.h>
#include <cstring>
#include <cwchar>
#include <cstdlib>
#include <cstdarg>
#include <cstdio>
#include <intrin.h>
#include <algorithm>
#include <vector>
#pragma comment(lib, "shell32.lib")

// Private debugger candidate. Ordinary builds never include this translation
// unit. A matching client and populated qualification are still required.
namespace paris_agent_capacity {
namespace {
constexpr std::uintptr_t image_base = 0x140000000ull, image_end = 0x14C301400ull;
struct buffer { std::uintptr_t data{}; void* reservation{}; std::size_t bytes{}; };
buffer agent_pool, sentient_pool, table8, table20;
bool active{};
utils::hook::detour engine_error_hook;
void engine_error(game::errorParm code,const char* format,...) {
    char message[4096]{};
    std::va_list arguments;
    va_start(arguments,format);
    std::vsnprintf(message,sizeof(message),format ? format : "",arguments);
    va_end(arguments);
    console::error("[Paris capacity engine error] code=%d caller=%p message=%s\n",static_cast<int>(code),_ReturnAddress(),message);
    engine_error_hook.invoke<void>(code,"%s",message);
}
struct patch { std::uintptr_t address{}; unsigned width{}; std::uint32_t before{}, after{}; };
std::vector<patch> plan;

unsigned private_port(bool dedicated) {
    int count{}; auto args = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!args) return 0;
    unsigned result{}, matches{}; bool loopback = !dedicated;
    for (int i = 0; i + 2 < count; ++i) if (!std::wcscmp(args[i], L"+set")) {
        if (!std::wcscmp(args[i+1], dedicated ? L"net_port" : L"paris_capacity_peer_port")) {
            wchar_t* end{}; const auto value = std::wcstoul(args[i+2], &end, 10);
            ++matches;
            if (end && !*end && value >= 27100 && value <= 27999) result = static_cast<unsigned>(value);
        }
        if (!std::wcscmp(args[i+1], L"net_ip") && !std::wcscmp(args[i+2], L"127.0.0.1")) loopback = true;
    }
    LocalFree(args); return matches == 1 && loopback ? result : 0;
}
void readable_code(std::uintptr_t address, unsigned width) {
    MEMORY_BASIC_INFORMATION info{};
    if (address < image_base || address >= image_end || width > image_end-address ||
        VirtualQuery(reinterpret_cast<void*>(address), &info, sizeof(info)) != sizeof(info) ||
        info.State != MEM_COMMIT || (info.Protect & PAGE_GUARD)) throw std::runtime_error("Capacity candidate code range unavailable");
    const auto start = reinterpret_cast<std::uintptr_t>(info.BaseAddress);
    const auto protect = info.Protect & 0xff;
    if (address < start || address-start+width > info.RegionSize ||
        (protect != PAGE_EXECUTE_READ && protect != PAGE_EXECUTE_READWRITE && protect != PAGE_EXECUTE_WRITECOPY))
        throw std::runtime_error("Capacity candidate requires readable executable code");
}
buffer reserve(std::size_t bytes) {
    const auto committed = (bytes + 32 + 4095) & ~std::size_t(4095);
    const auto total = committed + 8192;
    for (unsigned attempt = 0; attempt < 4096; ++attempt) {
        const auto wanted = 0x150000000ull + static_cast<std::uintptr_t>(attempt) * 0x10000;
        auto reservation = VirtualAlloc(reinterpret_cast<void*>(wanted), total, MEM_RESERVE, PAGE_NOACCESS);
        if (!reservation) continue;
        auto memory = VirtualAlloc(static_cast<char*>(reservation)+4096, committed, MEM_COMMIT, PAGE_READWRITE);
        if (!memory) { VirtualFree(reservation, 0, MEM_RELEASE); continue; }
        const auto data = reinterpret_cast<std::uintptr_t>(memory)+16;
        std::memset(reinterpret_cast<void*>(data-16), 0xA7, 16);
        std::memset(reinterpret_cast<void*>(data+bytes), 0xA7, 16);
        return {data, reservation, bytes};
    }
    throw std::runtime_error("Capacity candidate storage allocation failed");
}
void add(std::uintptr_t address, std::uint32_t before, std::uint32_t after, unsigned width=4) {
    readable_code(address, width);
    std::uint32_t actual{}; std::memcpy(&actual, reinterpret_cast<void*>(address), width);
    if (actual != before) throw std::runtime_error("Capacity candidate signature mismatch at " + std::to_string(address));
    plan.push_back({address,width,before,after});
}
void rip(std::uintptr_t field, std::uintptr_t before, std::uintptr_t after) {
    std::int32_t original{}, replacement{};
    if (!relative32(before,field+4,original) || !relative32(after,field+4,replacement))
        throw std::runtime_error("Capacity candidate RIP displacement overflow");
    add(field,static_cast<std::uint32_t>(original),static_cast<std::uint32_t>(replacement));
}
void rva(std::uintptr_t field, std::uint32_t before, std::uintptr_t after) {
    if (after < image_base || after-image_base > 0x7fffffff)
        throw std::runtime_error("Capacity candidate RVA overflow");
    add(field,before,static_cast<std::uint32_t>(after-image_base));
}
bool write(const patch& item, bool rollback) noexcept {
    DWORD previous{};
    auto address = reinterpret_cast<void*>(item.address);
    if (!VirtualProtect(address,item.width,PAGE_EXECUTE_READWRITE,&previous)) return false;
    const auto value = rollback ? item.before : item.after;
    std::memcpy(address,&value,item.width);
    const bool flushed = FlushInstructionCache(GetCurrentProcess(),address,item.width) != FALSE;
    DWORD ignored{}; const bool restored = VirtualProtect(address,item.width,previous,&ignored) != FALSE;
    return flushed && restored && !std::memcmp(address,&value,item.width);
}
void build_plan() {
    add(0x140C18D77,24,agents); // Selector feeds the existing dynamic SV reservations.
    add(0x1405AFFF6,42,characters); add(0x1405B0000,58,map_start);
    // G_InitGame also owns an independent literal reservation. Leaving it at
    // 58 lets a map entity occupy a new agent's slot (observed fatal at slot58).
    add(0x14B54FA72,58,map_start); add(0x14B54FA7C,58,map_start);
    add(0x140B6686F,58*0x3F8,map_start*0x3F8);
    // ClonePlayer/CloneAgent each keep eight corpse entities. Their independent
    // allocators must follow the expanded character range instead of42/50.
    add(0x140B67402,42,player_corpse_start,1);
    add(0x140C1BB22,50,agent_corpse_start,1);
    add(0x140007781,24,agents); // Character-reference reset across the real pool.
    for (const auto address : {0x140406F77ull,0x141238588ull,0x140C14B28ull,0x140C14BF3ull,0x140C14C96ull}) add(address,0x78180,agent_bytes);
    rip(0x14C1ED662,0x145C9E590,agent_pool.data);
    rip(0x140007788,0x145CA32A0,agent_pool.data+0x4D10);
    add(0x14B3C5D02,24,agents); // The following LEA retains its extra 42 sentients.
    add(0x140AF6331,0x2C60,sentient_bytes);
    rip(0x140AF6324,0x145C6F5A0,sentient_pool.data);
    rip(0x140AF6F2A,0x145C6F5A0,sentient_pool.data);
    add(0x1404494FD,24,agents,1); add(0x140449696,24,agents,1);
    // Server character information and its trailing per-player data stay in
    // one coherent object. The hunk reservation grows with both allocations.
    add(0x140B1F4FE,0x7A0D8,server_size); add(0x140449EE9,0x7A0D8,server_size);
    add(0x140449EAB,0x7A0D0,server_size-8);
    add(0x14044A0CA,0x798F8,0x798F8+character_growth);
    add(0x140B205B4,0x2B7130,0x2B7130+character_growth+(characters-42)*0x40);
    for (const auto address : {0x140B1F5ADull,0x140B1F5C3ull,0x140486F35ull,0x140486F4Bull,0x140486F63ull}) add(address,0xA88,reference_bytes);
    for (const auto address : {0x140434FD4ull,0x14044928Eull,0x14044936Cull,0x14048C1EEull,0x14048C2CCull}) add(address,42,characters);
    // Matching private client: character array, object strides, tail and all
    // observed visibility-array accesses. No old 42-byte field is overwritten.
    for (const auto address : {0x1402409DAull,0x140240A17ull,0x140240A83ull,0x140241AD9ull,0x140241AF3ull,0x140241BCCull,0x140241BDAull,0x140242BF6ull}) add(address,0xFDEA8,client_size);
    for (const auto address : {0x140240AA0ull,0x140241B15ull,0x140242C13ull}) add(address,0xFD7F8,client_tail);
    for (const auto address : {0x140180172ull,0x1401833EBull,0x14018340Bull,0x140183435ull,0x140D2BE4Aull}) add(address,0x86B17,client_flags);
    add(0x140242E22,41,characters-1,1); add(0x140242E3C,41,characters-1,1);
    // Fixed character work tables: preserve their record formats and counters.
    for (const auto field : {0x14049084Aull,0x140491BFBull,0x140AC6795ull,0x140AC683Aull,0x140AC6A76ull,0x140AC6AB4ull,0x140AC6C06ull,0x140AC6E74ull,0x140AC6EB1ull,0x140AC6F3Aull}) rip(field,0x145C51580,table8.data);
    rip(0x140AC6AD4,0x145C51582,table8.data+2);
    rip(0x140AC6ADE,0x145C516D2,table8.data+table8_bytes+2);
    for (const auto field : {0x140490882ull,0x140491C34ull,0x140AC6905ull,0x140AC6B03ull}) rip(field,0x145C516D0,table20.data);
    rip(0x140AC6B1A,0x145C52738,table20.data+table20_bytes);
    rva(0x140AC6B71,0x5C51580,table8.data); rva(0x140AC6B7B,0x5C51584,table8.data+4);
    rva(0x140AC6C7E,0x5C516D4,table20.data+4); rva(0x140AC6C99,0x5C516D2,table20.data+2);
    rva(0x140AC6CCE,0x5C516E0,table20.data+16); rva(0x140AC6CEB,0x5C516D0,table20.data);
    add(0x140AC67C1,42,characters,1); add(0x140AC686E,42,characters,1);
    add(0x140AC6933,210,characters*5); add(0x140AC6AC2,336,table8_bytes); add(0x140AC6B0E,4200,table20_bytes);
    std::sort(plan.begin(),plan.end(),[](const patch& a,const patch& b){return a.address<b.address;});
    for (std::size_t i=1;i<plan.size();++i) if (plan[i-1].address+plan[i-1].width>plan[i].address)
        throw std::runtime_error("Overlapping capacity candidate patches");
}
void check_guards() {
    if (!active) return;
    for (const auto& pool : {agent_pool,sentient_pool,table8,table20})
        for (unsigned i=0;i<16;++i) if (*reinterpret_cast<const unsigned char*>(pool.data-16+i)!=0xA7 ||
            *reinterpret_cast<const unsigned char*>(pool.data+pool.bytes+i)!=0xA7) {
            active=false; game::Com_Error(game::ERR_DROP,"Private capacity storage boundary changed"); return;
        }
}
class component final : public component_interface {
    void post_unpack() override {
        if (!utils::flags::has_flag("paris-capacity-64")) return;
        const bool dedicated = game::environment::is_dedi();
        if (!utils::flags::has_flag("paris-isolated-lab") || !utils::flags::has_flag("paris-debugger") ||
            !(utils::flags::has_flag("cpMode") || utils::flags::has_flag("zombies")) ||
            !utils::flags::has_flag(dedicated ? "paris-server-test" : "paris-server-client-test") || !private_port(dedicated))
            throw std::runtime_error("Capacity candidate requires an explicit private CP test identity and peer port");
        try {
            agent_pool=reserve(agent_bytes); sentient_pool=reserve(sentient_bytes);
            table8=reserve(table8_bytes); table20=reserve(table20_bytes);
            build_plan();
        } catch (...) {
            for (auto* pool : {&agent_pool,&sentient_pool,&table8,&table20}) {
                if (pool->reservation) VirtualFree(pool->reservation,0,MEM_RELEASE);
                *pool={};
            }
            throw;
        }
        std::size_t applied{};
        for (;applied<plan.size();++applied) if (!write(plan[applied],false)) {
            bool restored=write(plan[applied],true);
            while(applied) restored=write(plan[--applied],true) && restored;
            if (!restored) std::terminate();
            throw std::runtime_error("Capacity candidate transaction restored after failed code write");
        }
        active=true;
        // Private diagnostic only: preserve the engine's error/drop behavior
        // while retaining its reason before the client returns to frontend.
        readable_code(0x140B8D830,1);
        engine_error_hook.create(0x140B8D830,engine_error);
        scheduler::once([] {
            game::Dvar_RegisterInt("paris_native_agent_capacity",agents,agents,agents,game::DVAR_FLAG_NONE,"Private native capacity candidate");
            console::info("[Paris capacity candidate] installed agents=64 ordinary=48 special_headroom=16 characters=82 map_start=98 patches=%zu; gameplay_unqualified=1\n",plan.size());
        },scheduler::main);
        scheduler::loop(check_guards,scheduler::main,100ms);
        // Storage is intentionally process-resident, reused across maps. It
        // must outlive engine teardown; the OS releases it after process exit.
    }
};
}
bool installed() noexcept { return active; }
}
REGISTER_COMPONENT(paris_agent_capacity::component)
