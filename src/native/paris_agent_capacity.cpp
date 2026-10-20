#include <std_include.hpp>
#include "paris_agent_capacity.hpp"
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "scheduler.hpp"
#include "console/console.hpp"
#include "party.hpp"
#include "gui/gui.hpp"
#include <utils/io.hpp>
#include <d3d11.h>
#include <wrl/client.h>
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
#include <atomic>
#include <vector>
#pragma comment(lib, "shell32.lib")

// Explicit CP capacity profile; default builds omit this translation unit.
// A matching peer wire contract is required. Diagnostic hooks stay private.
namespace paris_agent_capacity {
namespace {
constexpr std::uintptr_t image_base = 0x140000000ull, image_end = 0x14C301400ull;
struct buffer { std::uintptr_t data{}; void* reservation{}; std::size_t bytes{}; };
buffer agent_pool, sentient_pool, table8, table20;
std::atomic_bool active{};
utils::hook::detour engine_error_hook;
utils::hook::detour character_render_hook;
utils::hook::detour agent_delta_hook;
std::atomic_uint observed_sparse_agent_deltas{};
bool force_sparse_agent_wire{};
void agent_delta(void* info,void* message,int time,const void* from,const void* to,int force) {
    const auto* row=to?to:from;
    unsigned number{};int previous{},before{};
    if(row)std::memcpy(&number,row,sizeof(number));
    std::memcpy(&previous,static_cast<const unsigned char*>(message)+0x2C,sizeof(previous));
    std::memcpy(&before,static_cast<const unsigned char*>(message)+0x28,sizeof(before));
    // Private stress only: choose the codec's valid explicit representation
    // for high indices, without changing agent-state bytes. A skipped record
    // must restore the previous predictor so both peers keep the same state.
    const bool explicit_probe=force_sparse_agent_wire && row && number>=64 && number<characters;
    if(explicit_probe) {
        const int reset=-1;
        std::memcpy(static_cast<unsigned char*>(message)+0x2C,&reset,sizeof(reset));
    }
    agent_delta_hook.invoke<void>(info,message,time,from,to,explicit_probe?1:force);
    int after{},reference{};
    std::memcpy(&after,static_cast<const unsigned char*>(message)+0x28,sizeof(after));
    std::memcpy(&reference,static_cast<const unsigned char*>(message)+0x2C,sizeof(reference));
    if(explicit_probe && (reference!=static_cast<int>(number) || after<=before))
        std::memcpy(static_cast<unsigned char*>(message)+0x2C,&previous,sizeof(previous));
    if(number>=64 && number<characters && (explicit_probe || static_cast<int>(number)!=previous+1) &&
       reference==static_cast<int>(number) && after>before && observed_sparse_agent_deltas.fetch_add(1)<20)
        console::info("[Paris capacity agent wire] explicit id=%u previous=%d removed=%u width=%u bits=%d\n",
            number,previous,to?0u:1u,character_bits,after-before);
}
std::uint64_t observed_characters[characters]{};
std::atomic_uint rendered_characters{};
std::atomic_bool capture_requested{};
void capture_probe_frame() {
    if(!capture_requested.exchange(false))return;
    try {
        // Same swap-chain selection as the pinned CB/Aurora GUI, called from
        // its render callback under the existing render mutex. No desktop UI.
        const int window=*reinterpret_cast<int*>(0x148B1BE34);
        if(window<0 || window>=2)throw std::runtime_error("No active game swap chain");
        auto* chain=reinterpret_cast<IDXGISwapChain**>(0x148B1BE48)[12*window];
        using Microsoft::WRL::ComPtr;
        ComPtr<ID3D11Texture2D> source,staging;
        if(!chain || FAILED(chain->GetBuffer(0,IID_PPV_ARGS(&source))))throw std::runtime_error("No back buffer");
        ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
        source->GetDevice(&device);device->GetImmediateContext(&context);
        D3D11_TEXTURE2D_DESC desc{};source->GetDesc(&desc);
        const bool rgba=desc.Format==DXGI_FORMAT_R8G8B8A8_UNORM || desc.Format==DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
        const bool bgra=desc.Format==DXGI_FORMAT_B8G8R8A8_UNORM || desc.Format==DXGI_FORMAT_B8G8R8A8_UNORM_SRGB;
        if((!rgba && !bgra) || !desc.Width || !desc.Height || desc.Width>8192 || desc.Height>8192 ||
            desc.ArraySize!=1 || desc.SampleDesc.Count!=1)throw std::runtime_error("Unsupported probe back buffer");
        auto copy=desc;copy.MipLevels=1;copy.Usage=D3D11_USAGE_STAGING;copy.BindFlags=0;
        copy.CPUAccessFlags=D3D11_CPU_ACCESS_READ;copy.MiscFlags=0;
        if(FAILED(device->CreateTexture2D(&copy,nullptr,&staging)))throw std::runtime_error("Probe staging allocation failed");
        context->CopySubresourceRegion(staging.Get(),0,0,0,0,source.Get(),0,nullptr);
        D3D11_MAPPED_SUBRESOURCE mapped{};
        if(FAILED(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped)))throw std::runtime_error("Probe map failed");
        struct unmap {ID3D11DeviceContext* context;ID3D11Texture2D* texture;~unmap(){context->Unmap(texture,0);}} guard{context.Get(),staging.Get()};
        BITMAPFILEHEADER file{};BITMAPINFOHEADER info{};
        file.bfType=0x4D42;file.bfOffBits=sizeof(file)+sizeof(info);file.bfSize=file.bfOffBits+desc.Width*desc.Height*4;
        info.biSize=sizeof(info);info.biWidth=static_cast<LONG>(desc.Width);info.biHeight=-static_cast<LONG>(desc.Height);
        info.biPlanes=1;info.biBitCount=32;info.biCompression=BI_RGB;
        std::string bytes(file.bfSize,'\0');std::memcpy(bytes.data(),&file,sizeof(file));
        std::memcpy(bytes.data()+sizeof(file),&info,sizeof(info));
        for(UINT y=0;y<desc.Height;++y) {
            const auto* row=static_cast<const unsigned char*>(mapped.pData)+y*mapped.RowPitch;
            auto* output=reinterpret_cast<unsigned char*>(bytes.data()+file.bfOffBits+y*desc.Width*4);
            for(UINT x=0;x<desc.Width;++x) {
                output[x*4]=row[x*4+(rgba?2:0)];output[x*4+1]=row[x*4+1];
                output[x*4+2]=row[x*4+(rgba?0:2)];output[x*4+3]=255;
            }
        }
        if(!utils::io::write_file("iw7-mod/screenshots/server-modules-fixture.bmp",bytes))throw std::runtime_error("Probe BMP write failed");
        console::info("[Paris capacity frame] saved pid=%lu models=%u width=%u height=%u\n",GetCurrentProcessId(),rendered_characters.load(),desc.Width,desc.Height);
    } catch(const std::exception& error) {console::error("[Paris capacity frame] failed: %s\n",error.what());}
}
void probe_fire(bool down) {
    const char* name=down?"+attack":"-attack";
    for(int binding=0;binding<118;++binding)if(game::command_whitelist[binding] &&
        std::strcmp(game::command_whitelist[binding],name)==0) {
        utils::hook::invoke<void>(0x14032A3B0,0,binding,200,game::Sys_Milliseconds());
        console::info("[Paris capacity fire] %s pid=%lu catchers=%d\n",down?"pressed":"released",GetCurrentProcessId(),*game::keyCatchers);return;
    }
    console::error("[Paris capacity fire] Retail binding absent: %s\n",name);
}
void character_render(int local_client,void* entity) {
    character_render_hook.invoke<void>(local_client,entity);
    auto state=static_cast<const unsigned char*>(entity)+0x700;
    std::uint16_t number{},animation{}; unsigned type{},client_number{},entity_flags{};
    std::memcpy(&number,state,sizeof(number));
    std::memcpy(&type,state+4,sizeof(type));
    std::memcpy(&client_number,state+0x9C,sizeof(client_number));
    std::memcpy(&animation,state+0xE6,sizeof(animation));
    std::memcpy(&entity_flags,state+8,sizeof(entity_flags));
    if(local_client==0 && number>=players && number<characters) {
        // Same character-info and DObj lookups used by the retail render path.
        // Their presence is diagnostic data; pixels still need inspection.
        auto object=reinterpret_cast<void*(*)(unsigned,int)>(0x140BB1560)(number,local_client);
        auto system=reinterpret_cast<void**>(0x141FAEE58)[local_client];
        auto vtable=*static_cast<void***>(system);
        auto info=reinterpret_cast<void*(*)(void*,unsigned)>(vtable[6])(system,client_number);
        unsigned valid{};std::memcpy(&valid,static_cast<unsigned char*>(info)+4,sizeof(valid));
        const auto signature=(static_cast<std::uint64_t>(type)<<48) |
            (static_cast<std::uint64_t>(client_number)<<16) | (animation&15) | 0x8000 |
            (object?0x100:0) | (valid?0x200:0);
        if(observed_characters[number]!=signature) {
            if((signature&0x300)==0x300 && (observed_characters[number]&0x300)!=0x300)++rendered_characters;
            else if((signature&0x300)!=0x300 && (observed_characters[number]&0x300)==0x300)--rendered_characters;
            observed_characters[number]=signature;
            console::info("[Paris capacity character] entity=%u type=%u client_num=%u animation_class=%u valid=%u dobj=%p flags=%08X\n",
                static_cast<unsigned>(number),type,client_number,static_cast<unsigned>(animation&15),valid,object,entity_flags);
        }
    }
}
void engine_error(game::errorParm code,const char* format,...) {
    char message[4096]{};
    std::va_list arguments;
    va_start(arguments,format);
    std::vsnprintf(message,sizeof(message),format ? format : "",arguments);
    va_end(arguments);
    console::error("[Paris capacity engine error] code=%d caller=%p message=%s\n",static_cast<int>(code),_ReturnAddress(),message);
    engine_error_hook.invoke<void>(code,"%s",message);
}
struct patch { std::uintptr_t address{}; unsigned width{}; std::uint32_t before{}, after{}; bool code{true}; };
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
void readable_netfield(std::uintptr_t field) {
    MEMORY_BASIC_INFORMATION info{};
    const auto address=field-4;
    if(address<0x141BB3F4C || address+12>0x141BB9EF8 ||
        VirtualQuery(reinterpret_cast<void*>(address),&info,sizeof(info))!=sizeof(info) ||
        info.State!=MEM_COMMIT || (info.Protect&PAGE_GUARD)) throw std::runtime_error("Capacity netfield unavailable");
    const auto start=reinterpret_cast<std::uintptr_t>(info.BaseAddress);
    const auto protect=info.Protect&0xff;
    if(address<start || address-start+12>info.RegionSize ||
        (protect!=PAGE_READONLY && protect!=PAGE_READWRITE && protect!=PAGE_WRITECOPY &&
            protect!=PAGE_EXECUTE_READ && protect!=PAGE_EXECUTE_READWRITE && protect!=PAGE_EXECUTE_WRITECOPY))
        throw std::runtime_error("Capacity netfield requires static readable data");
    std::uint32_t descriptor[3]{};
    std::memcpy(descriptor,reinterpret_cast<void*>(address),sizeof(descriptor));
    const auto hint=(field==0x141BB7460 || field==0x141BB775C || field==0x141BB7D98) ? 1u : 0u;
    if(descriptor[0]!=0x9C || descriptor[1]!=6 || descriptor[2]!=hint)
        throw std::runtime_error("Capacity clientNum netfield signature differs");
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
template<std::size_t N> void sequence(std::uintptr_t address,
    const std::array<std::uint8_t,N>& before,const std::array<std::uint8_t,N>& after) {
    // Validate the entire block, including unchanged opcodes, before the
    // installation transaction writes anything. No relocated branch/call.
    readable_code(address,static_cast<unsigned>(N));
    if(std::memcmp(reinterpret_cast<void*>(address),before.data(),N))
        throw std::runtime_error("Capacity animation instruction block differs");
    for(std::size_t i=0;i<N;++i)add(address+i,before[i],after[i],1);
}
void unwind_field(const animation_archive::query_patch& item) {
    // These exact static .rdata fields describe the three changed
    // stack frames, chained register saves and GS cookie locations.
    MEMORY_BASIC_INFORMATION info{};
    if(item.address<0x1416CCF0C || item.address+item.width>0x1416E29C4 ||
       (item.width!=2 && item.width!=4) ||
       VirtualQuery(reinterpret_cast<void*>(item.address),&info,sizeof(info))!=sizeof(info) ||
       info.State!=MEM_COMMIT || (info.Protect&PAGE_GUARD))throw std::runtime_error("Capacity query unwind range unavailable");
    const auto start=reinterpret_cast<std::uintptr_t>(info.BaseAddress);
    const auto protection=info.Protect&0xff;
    if(item.address<start || item.address-start+item.width>info.RegionSize ||
       (protection!=PAGE_READONLY && protection!=PAGE_READWRITE && protection!=PAGE_WRITECOPY &&
        protection!=PAGE_EXECUTE_READ && protection!=PAGE_EXECUTE_READWRITE && protection!=PAGE_EXECUTE_WRITECOPY))
        throw std::runtime_error("Capacity query requires static readable unwind data");
    std::uint32_t actual{};std::memcpy(&actual,reinterpret_cast<void*>(item.address),item.width);
    if(actual!=item.before)throw std::runtime_error("Capacity query unwind signature differs");
    plan.push_back({item.address,item.width,item.before,item.after,false});
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
    if (!VirtualProtect(address,item.width,item.code ? PAGE_EXECUTE_READWRITE : PAGE_READWRITE,&previous)) return false;
    const auto value = rollback ? item.before : item.after;
    std::memcpy(address,&value,item.width);
    const bool flushed = !item.code || FlushInstructionCache(GetCurrentProcess(),address,item.width) != FALSE;
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
    // The two corpse pools retain eight fixed 0x2CA0 client records each.
    // Move their entity-to-record indices together with the allocators; an old
    // subtraction indexes beyond that fixed pool as soon as an agent dies.
    for (const auto field : {0x1407AE403ull,0x140823B61ull,0x140826385ull,0x14086D122ull,0x140872E65ull}) add(field,42,player_corpse_start,1);
    for (const auto field : {0x1407AF52Full,0x140823B80ull,0x140865EB9ull,0x14086F509ull,0x140872EECull}) add(field,50,agent_corpse_start,1);
    add(0x1408213F4,0xCE,0xA6,1); // lea ebx,[entity-50] -> [entity-90].
    add(0x140B2F536,42,player_corpse_start,1); // Server owner lookup uses the combined 16-slot corpse index.
    // Character entity decoding, lookup, interpolation and teardown must agree
    // with the enlarged information arrays. The decoder otherwise drops the
    // first extra actor: "Received entnum 42: must index MAX_CHARACTERS_MP".
    for (const auto field : {0x14084A551ull,0x140842A20ull,0x140842B0Bull,
        0x14077EDEEull,0x1407801DEull,0x140780549ull,0x140805D4Eull,
        0x140282ED8ull,0x1402854DEull,0x1405C2578ull,0x140B202DCull}) add(field,42,characters,1);
    // Agent-state deltas carry a second, independent character identifier.
    // Consecutive records use the predictor and hide the old six-bit limit;
    // a sparse update/removal for agent64 instead aliases player0. Preserve
    // the existing predictor, record presence and removal fields; widen only
    // its explicit index at both writers and every live/demo reader.
    add(0x140BBFAB5,6,character_bits);
    add(0x140BBFB08,6,character_bits);
    add(0x1409B7542,6,character_bits);
    add(0x140C655D8,6,character_bits);
    add(0x140C65C51,6,character_bits);
    // Exact CP entity-state field lists contain 21 distinct clientNum records.
    // Their old six-bit wire field maps64->0 even though the server owns64.
    // Change the same descriptors on both private peers, preserving every
    // offset, change hint and unrelated six-bit field. Legacy peers cannot
    // share this opt-in wire layout.
    for(const auto field : {0x141BB3F50ull,0x141BB45FCull,0x141BB4790ull,0x141BB4A80ull,
        0x141BB4D64ull,0x141BB50C0ull,0x141BB5410ull,0x141BB576Cull,0x141BB59F0ull,
        0x141BB5C08ull,0x141BB5FB8ull,0x141BB61E8ull,0x141BB6634ull,0x141BB6858ull,
        0x141BB6B24ull,0x141BB6E50ull,0x141BB71E8ull,0x141BB7460ull,0x141BB775Cull,
        0x141BB7D98ull,0x141BB9EF0ull}) {
        readable_netfield(field);
        plan.push_back({field,4,6,character_bits,false});
    }
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
    add(0x140B205B4,0x2B7130,0x2B7130+character_growth+(characters-42)*0x40+animation_archive::growth);
    for (const auto address : {0x140B1F5ADull,0x140B1F5C3ull,0x140486F35ull,0x140486F4Bull,0x140486F63ull}) add(address,0xA88,reference_bytes);
    for (const auto address : {0x140434FD4ull,0x14044928Eull,0x14044936Cull,0x14048C1EEull,0x14048C2CCull}) add(address,42,characters);
    // Matching private client: character array, object strides, tail and all
    // observed visibility-array accesses. No old 42-byte field is overwritten.
    for (const auto address : {0x1402409DAull,0x140240A17ull,0x140240A83ull,0x140241AD9ull,0x140241AF3ull,0x140241BCCull,0x140241BDAull,0x140242BF6ull}) add(address,0xFDEA8,client_size);
    for (const auto address : {0x140240AA0ull,0x140241B15ull,0x140242C13ull}) add(address,0xFD7F8,client_tail);
    for (const auto address : {0x140180172ull,0x1401833EBull,0x14018340Bull,0x140183435ull,0x140D2BE4Aull}) add(address,0x86B17,client_flags);
    add(0x140242E22,41,characters-1,1); add(0x140242E3C,41,characters-1,1);
    // CL_GetSnapshot preserved entity states but silently truncated the
    // separate agentState list to24, leaving higher characterInfos invalid
    // and their DObjs absent. Grow both snapshot objects and initialization/
    // reset/selection strides before widening the metadata copy. Appending
    // avoids moving unrelated camera, FX and weapon fields after39F48.
    for(const auto address:{0x1408646D1ull,0x1408646EAull,0x140864726ull,0x1408648BDull})
        add(address,2*client_snapshot::legacy_size,client_snapshot::pair_bytes);
    for(const auto address:{0x14086470Dull,0x14086471Full,0x1408648E9ull,0x1408648FBull,0x14086C728ull})
        add(address,client_snapshot::legacy_size,client_snapshot::size);
    for(const auto address:{0x1408706ABull,0x140873602ull,0x1408738B3ull,0x1409934BFull})
        add(address,client_snapshot::legacy_agents,client_snapshot::agent_base);
    add(0x1409934A4,24,agents);
    // Keep the caller's three-word change mask off its saved cg pointer.
    // Clear its third word with the existing entity-bitset initialization;
    // that widened clear still ends at170, before the original GS cookie.
    add(0x14086FBE0,0x70,0x68,1);add(0x14086FBE3,0x100,0x108);
    add(0x14086FDAF,0x60,client_snapshot::saved_state,1);
    add(0x140870705,0x60,client_snapshot::saved_state,1);
    for(const auto address:{0x14086FE70ull,0x14086FE78ull,0x14086FE87ull,0x140870670ull,0x1408706D0ull})
        add(address,0x40,client_snapshot::change_mask,1);
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
    // CP lag compensation has its own fixed42 controller/XAnim archives.
    // In particular flags48/49 previously overlapped saved pointer0. Port
    // allocation, history stride, capture, readers, saved trees and cleanup
    // together; keep the generic entity history and restore context intact.
    using namespace animation_archive;
    add(0x140B1F55A,0x2077F0,object_size);
    add(0x14B431B51,0x2077F0,object_size); // Protected CP teardown memset.
    add(0x140445927,0xC7A8,frame_size);
    add(0x14044592D,0xC7A8,frame_size);
    add(0x140445A67,0xC7A8,frame_size);
    add(0x140445A73,0x1F5648,restore);
    add(0x14044608F,0x3C58,frame_size-controller_base);
    add(0x140445C33,0x9774,xanim_base);
    // The existing disp32-zero LEA feeds every controller-record write.
    // Moving its scaled result by10 adds80 bytes without a signed disp8.
    add(0x140445D2A,0,(controller_records-0x54)/8);
    add(0x140445DAB,0x150,xanim_counter);
    add(0x140445DBE,0x55,xanim_data/4);
    add(0x140445DDA,0xA8,xanim_counts);
    add(0x140445DE0,0x150,xanim_counter);
    for(const auto address:{0x140445AB8ull,0x140445B5Full,0x140445B96ull,0x140445ED2ull})
        add(address,0x2077E8,rewind_base+rewind_active);
    add(0x140445ACE,0x207698,rewind_base+pointers);
    add(0x140445ADF,0x20766C,rewind_base+flags);
    add(0x140445B7B,0x207668,rewind_base+0x10);
    for(const auto address:{0x140445B82ull,0x140445EDCull})add(address,0x207658,rewind_base);
    add(0x140445B90,0x207660,rewind_base+8);
    add(0x140445B45,42,characters,1);
    add(0x140445F0C,42,characters);
    add(0x1400A8585,42,characters);
    add(0x140415C28,0x40,pointers,1);
    for(const auto address:{0x140414E42ull,0x140414E78ull,
        0x1404151BCull,0x1404151E7ull,0x140415264ull,0x1404152EAull})
        add(address,0xCCC,controller_size+xanim_counts);
    for(const auto address:{0x1404151A7ull,0x1404151DAull,0x140415254ull,0x1404152DAull})
        add(address,0xC24,controller_size);
    for(const auto address:{0x1404151C3ull,0x1404151EEull,0x14041526Bull,0x1404152F1ull})
        add(address,0x1AF,(controller_size+xanim_data)/8);
    sequence(0x140415205,blend_before,blend_after);
    sequence(0x14041527F,next_before,next_after);
    sequence(0x140415305,previous_before,previous_after);
    for(const auto& item:query_code)add(item.address,item.before,item.after,item.width);
    for(const auto& item:query_unwind)unwind_field(item);
    std::sort(plan.begin(),plan.end(),[](const patch& a,const patch& b){return a.address<b.address;});
    for (std::size_t i=1;i<plan.size();++i) if (plan[i-1].address+plan[i-1].width>plan[i].address)
        throw std::runtime_error("Overlapping capacity candidate patches");
}
void check_guards() {
    if (!active) return;
    for (const auto& pool : {agent_pool,sentient_pool,table8,table20})
        for (unsigned i=0;i<16;++i) if (*reinterpret_cast<const unsigned char*>(pool.data-16+i)!=0xA7 ||
            *reinterpret_cast<const unsigned char*>(pool.data+pool.bytes+i)!=0xA7) {
            // Installed patches remain process-resident. Never downgrade the
            // peer contract to24 while the 64-agent layout is still installed.
            game::Com_Error(game::ERR_FATAL,"Capacity storage boundary changed"); return;
        }
}
class component final : public component_interface {
    void post_unpack() override {
        if (!utils::flags::has_flag("paris-capacity-64")) return;
        const bool dedicated = game::environment::is_dedi();
        const bool production=utils::flags::has_flag("paris-capacity-production");
        const bool sparse_probe=utils::flags::has_flag("paris-capacity-sparse-wire-probe");
        if(sparse_probe && (production || !dedicated))
            throw std::runtime_error("Sparse wire probe requires the private dedicated identity");
        const bool client_probe=utils::flags::has_flag("paris-capacity-client-probe");
        const bool probe_capture=utils::flags::has_flag("paris-capacity-client-capture");
        const bool probe_shoot=utils::flags::has_flag("paris-capacity-client-fire");
        const auto probe_port=client_probe ? private_port(false) : 0;
        if((probe_capture || probe_shoot) && !client_probe)throw std::runtime_error("Capacity capture/fire requires the private client probe");
        if(client_probe && (!production || dedicated || !probe_port))
            throw std::runtime_error("Normal capacity client probe requires its explicit private loopback peer port");
        if(!(utils::flags::has_flag("cpMode") || utils::flags::has_flag("zombies")))
            throw std::runtime_error("Expanded capacity requires explicit CP mode");
        if(production) {
            if(utils::flags::has_flag("paris-isolated-lab") || utils::flags::has_flag("paris-debugger") ||
                utils::flags::has_flag("paris-server-test") || utils::flags::has_flag("paris-server-client-test"))
                throw std::runtime_error("Production capacity cannot use private qualification identities");
        } else if (!utils::flags::has_flag("paris-isolated-lab") || !utils::flags::has_flag("paris-debugger") ||
            !utils::flags::has_flag(dedicated ? "paris-server-test" : "paris-server-client-test") || !private_port(dedicated))
            throw std::runtime_error("Capacity candidate requires an explicit private CP test identity and peer port");
        force_sparse_agent_wire=sparse_probe;
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
        if(production && !dedicated) {
            // The upstream -cpMode flag selects dedicated mode only. Honor
            // this explicitly CP-only client profile after engine startup.
            const auto deadline=GetTickCount64()+120000;
            scheduler::loop([probe_port,deadline,entered=false,finished=false]() mutable {
                    if(finished || GetTickCount64()>=deadline) return;
                    if(entered && !probe_port) {finished=true;return;}
                    if(game::Com_GameMode_GetActiveGameMode()!=game::GAME_MODE_CP) {
                        if(entered) return;
                        game::Com_GameMode_SetDesiredGameMode(game::GAME_MODE_CP); return;
                    }
                    entered=true;
                    if(!probe_port) {finished=true;return;}
                    if(game::Live_SyncOnlineDataFlags(0)!=0) return;
                    game::netadr_s target{};target.type=game::NA_IP;
                    target.ip[0]=127;target.ip[3]=1;target.port=htons(static_cast<unsigned short>(probe_port));
                    finished=true;party::connect(target);
                    console::info("[Paris capacity client probe] Ready loopback join to UDP %u.\n",probe_port);
            },scheduler::main,100ms);
        }
        // Private diagnostic only: preserve the engine's error/drop behavior
        // while retaining its reason before the client returns to frontend.
        if(!production) {
            readable_code(0x140B8D830,1);
            engine_error_hook.create(0x140B8D830,engine_error);
            if(dedicated) {
                readable_code(0x140BBFA30,1);
                agent_delta_hook.create(0x140BBFA30,agent_delta);
            }
        }
        if(!dedicated && (!production || client_probe)) {
            readable_code(0x1408260D0,1);
            character_render_hook.create(0x1408260D0,character_render);
        }
        if(client_probe && (probe_capture || probe_shoot)) {
            if(probe_capture){gui::enable();gui::on_frame(capture_probe_frame,true,false);}
            scheduler::loop([probe_port,probe_capture,probe_shoot,ready=0ull,last_shot=0ull,shots=0u,pressed=false,released=false,done=false]() mutable {
                if(done)return;
                const auto now=GetTickCount64();const auto* peer=party::get_server_connection_state();
                const bool connected=peer && peer->hostDefined && peer->host.type==game::NA_IP &&
                    peer->host.ip[0]==127 && peer->host.ip[1]==0 && peer->host.ip[2]==0 && peer->host.ip[3]==1 &&
                    ntohs(peer->host.port)==probe_port && game::Com_GameMode_GetActiveGameMode()==game::GAME_MODE_CP;
                if(pressed && !released && (!connected || now-last_shot>=200)) {probe_fire(false);released=true;}
                if(!connected || rendered_characters.load()<ordinary)return;
                if(!ready){ready=now;return;}
                if(now-ready>=30000 && (!probe_shoot || shots<8)) {
                    console::error("[Paris capacity fire] Probe expired before idle input. catchers=%d\n",*game::keyCatchers);
                    if(probe_capture)capture_requested=true;done=true;return;
                }
                if(probe_shoot && (!pressed || released) && shots<8 && now-ready>=5000 && now-last_shot>=1000 && *game::keyCatchers==0){
                    probe_fire(true);pressed=true;released=false;last_shot=now;++shots;
                }
                if(now-ready>=7000 && (!probe_shoot || (shots==8 && released))) {
                    if(probe_capture)capture_requested=true;done=true;
                }
            },scheduler::main,50ms);
        }
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
