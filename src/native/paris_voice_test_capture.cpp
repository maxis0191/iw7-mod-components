#include <std_include.hpp>
#define IW7_PARIS_ISOLATED_VOICE_CAPTURE 1
#include "paris_voice_test_capture.hpp"
#include "voice_test_capture.hpp"
#include "voice_test_binding.hpp"
#include "voice_relay.hpp"
#include "paris_test_safety.hpp"
#include "game/game.hpp"
#include "scripting.hpp"
#include "console/console.hpp"
#include <utils/flags.hpp>
#include <utils/hook.hpp>
#include <utils/cryptography.hpp>
#include <shellapi.h>
#include <filesystem>
#include <mutex>
#include <memory>

namespace paris_voice_test_capture {
namespace {
struct provider {
    HANDLE image=INVALID_HANDLE_VALUE,source=INVALID_HANDLE_VALUE,marker=INVALID_HANDLE_VALUE;
    std::mutex mutex;
    voice_test_binding::observation cached,bound;
    voice_test_capture::admission scope;
    std::vector<unsigned char> wav;
    FILETIME created{};
    std::string recorder_challenge;
    ~provider(){if(marker!=INVALID_HANDLE_VALUE)CloseHandle(marker);if(source!=INVALID_HANDLE_VALUE)CloseHandle(source);if(image!=INVALID_HANDLE_VALUE)CloseHandle(image);}
};
std::shared_ptr<provider> state;
std::shared_ptr<voice_test_capture::control> control;
utils::hook::detour volume_hook;
bool installed{},armed{},cancelled{},cancel_acknowledged{};
bool protection_seen{},startup_shutdown_preserved{};
std::recursive_mutex lifecycle;
std::uint64_t last_report{},last_state_report{};
DWORD main_tid{};
LPDIRECTSOUNDCAPTURE* const expected_output=reinterpret_cast<LPDIRECTSOUNDCAPTURE*>(0x145D5DC48);
std::wstring argument(const wchar_t* prefix) {
    int count{};auto** args=CommandLineToArgvW(GetCommandLineW(),&count);
    if(!args)throw std::runtime_error("Fake capture arguments unavailable");
    std::wstring result;unsigned matches{};
    for(int i=1;i<count;++i)if(std::wcsncmp(args[i],prefix,std::wcslen(prefix))==0){++matches;result=args[i]+std::wcslen(prefix);}
    LocalFree(args);if(matches!=1 || result.empty())throw std::runtime_error("Exact nonempty fake capture selector required");return result;
}
HANDLE retain(const std::wstring& path,std::uint64_t maximum,std::vector<unsigned char>& bytes) {
    const auto absolute=std::filesystem::path(path);
    if(!absolute.is_absolute())throw std::runtime_error("Absolute retained source required");
    for(auto part=absolute;!part.empty();part=part.parent_path()){
        const auto attrs=GetFileAttributesW(part.c_str());
        if(attrs==INVALID_FILE_ATTRIBUTES || (attrs&FILE_ATTRIBUTE_REPARSE_POINT))throw std::runtime_error("Missing/redirected source path");
        if(part==part.parent_path())break;
    }
    struct handle_closer {void operator()(void* h) const noexcept{if(h && h!=INVALID_HANDLE_VALUE)CloseHandle(h);}};
    std::unique_ptr<void,handle_closer> retained(CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));
    const auto h=retained.get();
    if(h==INVALID_HANDLE_VALUE)throw std::runtime_error("Source retention failed");
    LARGE_INTEGER size{};
    if(!GetFileSizeEx(h,&size) || size.QuadPart<=0 || static_cast<std::uint64_t>(size.QuadPart)>maximum){throw std::runtime_error("Source size bound");}
    bytes.resize(static_cast<size_t>(size.QuadPart));DWORD read{};
    if(!ReadFile(h,bytes.data(),static_cast<DWORD>(bytes.size()),&read,nullptr) || read!=bytes.size()){throw std::runtime_error("Source read differs");}
    return retained.release();
}
std::string exact_hash(const std::wstring& text) {
    if(text.size()!=64 || text.find_first_not_of(L"0123456789abcdef")!=std::wstring::npos)throw std::runtime_error("Lowercase source hash required");
    return std::string(text.begin(),text.end());
}
std::uint64_t now(void*) noexcept{return GetTickCount64();}
bool fresh(void* opaque,const voice_test_capture::admission& a,std::uint64_t tick) noexcept {
    try {
        auto& p=*static_cast<provider*>(opaque);std::lock_guard lock(p.mutex);
        return voice_test_binding::current(p.cached,tick) && voice_test_binding::same(p.bound,p.cached) &&
            p.cached.pid==a.process_id && p.cached.port==a.server_port && p.cached.relay_slot==a.slot &&
            p.cached.nonce==a.client_nonce && p.cached.protection_generation==a.server_generation;
    }catch(...){return false;}
}
bool read_request(voice_test_binding::arm_request& request,bool is_cancel=false) noexcept {
    try {
        std::vector<unsigned char> bytes;
        struct closer {void operator()(void* h)const noexcept{if(h && h!=INVALID_HANDLE_VALUE)CloseHandle(h);}};
        std::unique_ptr<void,closer> file(retain(std::filesystem::absolute(L"iw7-mod/paris-voice-capture.arm").wstring(),256,bytes));
        BY_HANDLE_FILE_INFORMATION info{};
        if(!GetFileInformationByHandle(file.get(),&info) || info.nNumberOfLinks!=1 ||
            (info.dwFileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY)) ||
            CompareFileTime(&info.ftLastWriteTime,&state->created)<0)return false;
        const std::string wire(bytes.begin(),bytes.end());
        return is_cancel?voice_test_binding::parse_cancel(wire,request):voice_test_binding::parse_arm(wire,request);
    }catch(...){return false;}
}
HRESULT WINAPI factory(LPCGUID guid,LPDIRECTSOUNDCAPTURE* output,LPUNKNOWN outer) {
    try {
    std::lock_guard lifecycle_guard(lifecycle);
    if(!state || !installed || cancelled || guid || outer || output!=expected_output || *output || control)return DSERR_INVALIDPARAM;
    voice_test_capture::environment env;env.owner=state;env.opaque=state.get();env.now=now;env.fresh=fresh;
    const auto hr=voice_test_capture::prepare(state->scope,env,state->wav,output,&control);
    console::info("[paris-fake-capture] Prepared factory pid=%lu hr=0x%08X tick_ms=%llu\n",GetCurrentProcessId(),static_cast<unsigned>(hr),GetTickCount64());
    return hr; // Never call a real/default capture factory on failure.
    }catch(...){return DSERR_INVALIDPARAM;}
}
void volume_init() noexcept {
    try {
    std::lock_guard lifecycle_guard(lifecycle);
    // Hook exists only for this admitted opt-in. Refuse any owner appearing
    // after admission instead of invoking an endpoint API or modifying it.
    if(!state || !installed || cancelled || *reinterpret_cast<void**>(0x1477A0190) || *reinterpret_cast<const int*>(0x1477A0188)) {
        cancel();console::error("[paris-fake-capture] Volume admission changed; cancelled pid=%lu; owner/default/gain untouched.\n",GetCurrentProcessId());return;
    }
    // Leave initialized false; retail setters are gated. No device/gain call.
    }catch(...){cancel();}
}
}
void cancel() noexcept {
    try {
    std::lock_guard lifecycle_guard(lifecycle);
    cancelled=true;if(control)control->cancel();
    if(state){std::lock_guard lock(state->mutex);state->cached={};}
    }catch(...){}
}
bool talk_admitted() noexcept {
    try {
        std::lock_guard lifecycle_guard(lifecycle);
        if(GetCurrentThreadId()!=main_tid || !installed || cancelled || !armed || !state || !control)return false;
        const auto m=control->snapshot();
        return m.armed && !m.failed && fresh(state.get(),state->scope,GetTickCount64());
    }catch(...){return false;}
}
void relay_main_tick() noexcept {
    try {
        std::lock_guard lifecycle_guard(lifecycle);
        if(!installed || !state)return;
        main_tid=GetCurrentThreadId();
        voice_test_binding::arm_request cancel_request;
        if(!cancel_acknowledged && read_request(cancel_request,true) &&
            voice_test_binding::admit_cancel(cancel_request,state->bound,state->scope.source_sha256,state->recorder_challenge,GetTickCount64())) {
            cancel();
            if(!control)return;const auto stopped=control->snapshot();
            if(!stopped.failed || stopped.armed)return;
            cancel_acknowledged=true;
            console::info("[paris-fake-capture] Cancelled request pid=%lu nonce=%s gen=%s slot=%u recorder_challenge=%s tick_ms=%llu\n",
                GetCurrentProcessId(),cancel_request.nonce.c_str(),cancel_request.generation.c_str(),cancel_request.slot,cancel_request.recorder_challenge.c_str(),GetTickCount64());
            return;
        }
        if(cancelled)return;
        const auto report_tick=GetTickCount64();
        if(control && (!last_report || report_tick-last_report>=1000)) {
            last_report=report_tick;const auto m=control->snapshot();
            console::info("[paris-fake-capture] Observed pid=%lu tick_ms=%llu prepared=%u armed=%u failed=%u buffer_started=%u locked=%u rate=%u channels=%u bits=%u align=%u buffer_bytes=%u source_frames=%llu published_frames=%llu source_output_frames=%llu nonzero_frames=%llu lock_calls=%llu lock_bytes=%llu lock_nonzero_bytes=%llu prepared_lock_bytes=%llu unlock_calls=%llu unlock_bytes=%llu\n",
                GetCurrentProcessId(),report_tick,static_cast<unsigned>(m.prepared),static_cast<unsigned>(m.armed),static_cast<unsigned>(m.failed),static_cast<unsigned>(m.buffer_started),static_cast<unsigned>(m.buffer_locked),
                m.rate,m.channels,m.bits,m.block_align,m.buffer_bytes,m.source_frames,m.published_frames,m.published_source_frames,m.published_nonzero_frames,
                m.lock_calls,m.lock_bytes,m.lock_nonzero_bytes,m.prepared_lock_bytes,m.unlock_calls,m.unlock_bytes);
        }
        const auto relay=voice_relay::test_readiness(); // v2 mutex already released.
        const auto protected_client=paris_test_fixture::capture_protection();
        protection_seen=protection_seen || protected_client.protected_now || !protected_client.nonce.empty();
        voice_test_binding::observation o;
        o.relay_ready=relay.ready && relay.both_roles_ready;o.loopback=relay.loopback;o.protected_now=protected_client.protected_now;
        o.slot_correlated=protected_client.slot_correlated;o.pid=protected_client.pid;o.port=protected_client.port;
        o.relay_slot=relay.slot;o.protected_slot=protected_client.slot;o.protected_query_tick=protected_client.query_tick;
        o.observed_tick=GetTickCount64();o.nonce=protected_client.nonce;o.protection_generation=protected_client.generation;
        o.challenge=relay.game_challenge;o.relay_generation_low=relay.speaker_generation_low;o.relay_generation_high=relay.speaker_generation_high;
        const auto tick=GetTickCount64();
        if(!last_state_report || tick-last_state_report>=100) {
            last_state_report=tick;
            console::info("[paris-voice-pair] STATE; pid=%lu; nonce=%s; gen=%s; slot=%u; query_tick=%llu; tick_ms=%llu; relay_gen_low=%llu; relay_gen_high=%llu; both_ready=%u; ui_ready=%u; talk_valid=%u; talk_key0=%d; talk_key1=%d; talk_active=%u.\n",
                GetCurrentProcessId(),o.nonce.empty()?"none":o.nonce.c_str(),o.protection_generation.empty()?"none":o.protection_generation.c_str(),o.protected_slot,
                o.protected_query_tick,tick,o.relay_generation_low,o.relay_generation_high,static_cast<unsigned>(voice_test_binding::current(o,tick)),
                static_cast<unsigned>(protected_client.ui_ready),static_cast<unsigned>(protected_client.talk_valid),protected_client.talk_key0,protected_client.talk_key1,protected_client.talk_active);
        }
        if(o.port!=relay.server_port || o.port!=state->scope.server_port || o.relay_slot!=state->scope.slot ||
            o.pid!=GetCurrentProcessId() || !voice_test_binding::current(o,tick)) {
            if(armed)cancel();else{std::lock_guard lock(state->mutex);state->cached={};}
            return;
        }
        {std::lock_guard lock(state->mutex);if(armed && !voice_test_binding::same(state->bound,o)){state->cached={};}
            else{state->cached=o;if(!armed)state->bound=o;}}
        if(armed){if(!fresh(state.get(),state->scope,tick))cancel();return;}
        if(!control || !relay.both_roles_ready || !protected_client.ui_ready || !protected_client.talk_valid ||
            protected_client.talk_key0 || protected_client.talk_key1 || protected_client.talk_active)return; // Receiver may remain Prepared silence.
        voice_test_binding::arm_request request;
        if(!read_request(request) || !voice_test_binding::admit_arm(request,o,state->scope.source_sha256,GetTickCount64()))return;
        auto a=state->scope;a.client_nonce=o.nonce;a.server_generation=o.protection_generation;a.slot=o.relay_slot;
        a.admitted_tick=GetTickCount64();a.deadline_tick=a.admitted_tick+30000;
        const auto hr=control->arm(a);
        // Buffer Start/Lock may not yet allow arm; retry only this same binding.
        if(SUCCEEDED(hr)){state->scope=a;state->recorder_challenge=request.recorder_challenge;armed=true;
            console::info("[paris-fake-capture] Armed relayv2 pid=%lu nonce=%s gen=%s slot=%u port=%u query_tick=%llu deadline=%llu recorder_challenge=%s tick_ms=%llu\n",
                a.process_id,a.client_nonce.c_str(),a.server_generation.c_str(),a.slot,a.server_port,o.protected_query_tick,a.deadline_tick,state->recorder_challenge.c_str(),GetTickCount64());}
        else if(hr!=DSERR_INVALIDCALL)cancel();
    }catch(...){cancel();}
}
void install() {
    if(!utils::flags::has_flag("paris-voice-fake-capture")){
        if(std::wcsstr(GetCommandLineW(),L"-paris-fake-capture-"))throw std::runtime_error("Orphan fake capture selectors refused");
        return;
    }
    if(std::wcsstr(GetCommandLineW(),L"-paris-lab-capture-"))throw std::runtime_error("Fake and endpoint selectors are mutually exclusive");
    if(game::environment::is_dedi() || !utils::flags::has_flag("paris-isolated-lab") ||
        !utils::flags::has_flag("paris-server-client-test") || !utils::flags::has_flag("paris-voice-audio-lab") ||
        !utils::flags::has_flag("iw7-voice-relay"))throw std::runtime_error("Fake capture explicit isolated relayv2 client required");
    auto p=std::make_shared<provider>();std::vector<unsigned char> marker;
    FILETIME exit{},kernel{},user{};
    if(!GetProcessTimes(GetCurrentProcess(),&p->created,&exit,&kernel,&user))throw std::runtime_error("Fake process creation unavailable");
    p->marker=retain(std::filesystem::absolute(L"iw7-mod/paris-isolated-lab.marker").wstring(),64,marker);
    if(std::string(marker.begin(),marker.end())!="iw7-paris-isolated-lab-v1")throw std::runtime_error("Fake capture marker differs");
    // The loader remaps PEB module names to iw7_ship.exe. Pin the original OS process image.
    wchar_t image[MAX_PATH]{};DWORD length=MAX_PATH;
    if(!QueryFullProcessImageNameW(GetCurrentProcess(),0,image,&length) || !length || length>=MAX_PATH)
        throw std::runtime_error("Fake image identity missing");
    std::vector<unsigned char> image_bytes;p->image=retain(image,64*1024*1024,image_bytes);
    const auto image_hash=utils::cryptography::sha256::compute(std::string(image_bytes.begin(),image_bytes.end()),true);
    auto normalized_hash=image_hash;for(auto& c:normalized_hash)if(c>='A' && c<='F')c=static_cast<char>(c-'A'+'a');
    if(normalized_hash!=exact_hash(argument(L"-paris-fake-capture-image-sha256=")))throw std::runtime_error("Fake image hash differs");
    p->source=retain(argument(L"-paris-fake-capture-wav="),480102,p->wav);
    if(p->wav.size()<44)throw std::runtime_error("Fake WAV truncated");
    auto& a=p->scope;a.source_sha256=exact_hash(argument(L"-paris-fake-capture-sha256="));
    auto wav_hash=utils::cryptography::sha256::compute(std::string(p->wav.begin(),p->wav.end()),true);
    for(auto& c:wav_hash)if(c>='A' && c<='F')c=static_cast<char>(c-'A'+'a');
    if(wav_hash!=a.source_sha256)throw std::runtime_error("Retained fake WAV hash differs");
    const auto port=argument(L"-paris-fake-capture-port=");
    if(port.size()!=5 || port.find_first_not_of(L"0123456789")!=std::wstring::npos)throw std::runtime_error("Fake port format");
    a.server_port=static_cast<unsigned>(std::stoul(port));
    if(a.server_port<27100 || a.server_port>27999)throw std::runtime_error("Fake port scope");
    const auto slot=argument(L"-paris-fake-capture-slot=");
    if(slot!=L"0" && slot!=L"1")throw std::runtime_error("Exact fake test role slot0/1 required");
    a.slot=slot==L"0" ? 0u : 1u;
    if(*expected_output || *reinterpret_cast<void**>(0x1477A0190) || *reinterpret_cast<const int*>(0x1477A0188))throw std::runtime_error("Existing capture/volume owner refused");
    const bool signature=std::memcmp(reinterpret_cast<const void*>(0x140B7A082),"\x45\x33\xc0\x48\x89\x05\xcc\x3b\x1e\x05\x48\x8d\x15\xb5\x3b\x1e\x05\x33\xc9\xe8\x74\x3e\x64\x00",24)==0 &&
        std::memcmp(reinterpret_cast<const void*>(0x140D5A2E0),"\x48\x83\xec\x38\x83\x3d\x9d\x5e\xa4\x06\x01",11)==0;
    if(!signature)throw std::runtime_error("Fake retail signatures differ");
    a.requested=a.isolated_build=a.isolated_flag=a.client_test_flag=a.voice_test_flag=true;
    a.marker_verified=a.owned_identity=a.signatures_verified=a.capture_owner_absent=a.volume_owner_absent=true;
    a.process_id=GetCurrentProcessId();a.admitted_tick=GetTickCount64();a.deadline_tick=a.admitted_tick+120000;
    state=p;installed=true;
    utils::hook::call(0x140B7A095,reinterpret_cast<void*>(factory));volume_hook.create(0x140D5A2E0,volume_init);
    scripting::on_shutdown([](bool full_clear,bool post){
        if(post)return;
        try {
            std::lock_guard lifecycle_guard(lifecycle);
            const auto tick=GetTickCount64();
            const bool main_thread=main_tid && main_tid==GetCurrentThreadId();
            if(main_thread){
                const auto latest=paris_test_fixture::capture_protection();
                protection_seen=protection_seen || latest.protected_now || !latest.nonce.empty();
            }
            const bool bound=state && !state->bound.nonce.empty();
            const bool failed=control && control->snapshot().failed;
            const bool admitted=installed && state && state->scope.process_id==GetCurrentProcessId() &&
                !*reinterpret_cast<void**>(0x1477A0190) && !*reinterpret_cast<const int*>(0x1477A0188);
            const voice_test_binding::startup_shutdown observed{admitted,
                main_thread,startup_shutdown_preserved,armed,cancelled,
                protection_seen,bound,failed,state?state->scope.admitted_tick:0,
                state?state->scope.deadline_tick:0,tick};
            const bool preserve=voice_test_binding::preserve_startup_shutdown(observed);
            console::info("[paris-fake-capture] Shutdown pre pid=%lu full_clear=%u action=%s admitted=%u main_thread=%u armed=%u protection_seen=%u binding_seen=%u capture_failed=%u already_preserved=%u admitted_tick=%llu deadline_tick=%llu tick_ms=%llu\n",
                GetCurrentProcessId(),static_cast<unsigned>(full_clear),preserve?"preserve_startup":"cancel",
                static_cast<unsigned>(admitted),static_cast<unsigned>(main_thread),static_cast<unsigned>(armed),
                static_cast<unsigned>(protection_seen),static_cast<unsigned>(bound),static_cast<unsigned>(failed),
                static_cast<unsigned>(startup_shutdown_preserved),observed.admitted_tick,observed.deadline_tick,tick);
            if(preserve){startup_shutdown_preserved=true;return;}
            cancel();
        }catch(...){cancel();}
    });
}
}
