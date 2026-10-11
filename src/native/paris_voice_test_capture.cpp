#include <std_include.hpp>
#define IW7_PARIS_ISOLATED_VOICE_CAPTURE 1
#include "paris_voice_test_capture.hpp"
#include "voice_test_capture.hpp"
#include "voice_test_binding.hpp"
#include "voice_pcm_witness.hpp"
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
bool codec_observed{};
bool protection_seen{},startup_shutdown_preserved{};
std::recursive_mutex lifecycle;
std::uint64_t last_report{},last_state_report{};
DWORD main_tid{};
utils::hook::detour received_decode_hook,received_enqueue_hook;
bool received_enabled{},received_finished{};
std::wstring received_path;
std::unique_ptr<voice_pcm_witness::buffer> received_pcm;
voice_pcm_witness::scope received_scope;
voice_test_binding::observation received_binding;
unsigned received_rate{},frequency_min{},frequency_max{};
struct received_frame_context {
    voice_pcm_witness::frame frame;
    const short* decoded_pointer{};
    void* playback_buffer{};
    bool decoded{},enqueued{},invalid{};
};
thread_local received_frame_context* received_context{};
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
bool read_request(voice_test_binding::arm_request& request,bool is_cancel=false,
    const wchar_t* mailbox=L"iw7-mod/paris-voice-capture.arm") noexcept {
    try {
        std::vector<unsigned char> bytes;
        struct closer {void operator()(void* h)const noexcept{if(h && h!=INVALID_HANDLE_VALUE)CloseHandle(h);}};
        std::unique_ptr<void,closer> file(retain(std::filesystem::absolute(mailbox).wstring(),256,bytes));
        BY_HANDLE_FILE_INFORMATION info{};
        if(!GetFileInformationByHandle(file.get(),&info) || info.nNumberOfLinks!=1 ||
            (info.dwFileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY)) ||
            CompareFileTime(&info.ftLastWriteTime,&state->created)<0)return false;
        const std::string wire(bytes.begin(),bytes.end());
        return is_cancel?voice_test_binding::parse_cancel(wire,request):voice_test_binding::parse_arm(wire,request);
    }catch(...){return false;}
}
bool received_fresh(std::uint64_t tick) {
    if(!state || cancelled || received_finished || !received_pcm)return false;
    std::lock_guard lock(state->mutex);
    return voice_test_binding::current(state->cached,tick) && voice_test_binding::same(received_binding,state->cached);
}
int received_decode(const char* data,int length,short* pcm,int samples) {
    const auto result=received_decode_hook.invoke<int>(data,length,pcm,samples);
    if(auto* c=received_context){
        try {
            if(c->decoded || !pcm || samples<=0 || samples>4096 || result!=samples*2){c->invalid=true;return result;}
            c->decoded=true;c->decoded_pointer=pcm;c->frame.samples=samples;
            c->frame.decoded.assign(pcm,pcm+samples);
        }catch(...){c->invalid=true;}
    }
    return result;
}
int received_enqueue(void* buffer,const short* pcm,int bytes) {
    const auto result=received_enqueue_hook.invoke<int>(buffer,pcm,bytes);
    if(auto* c=received_context){
        try {
            if(c->enqueued || !c->decoded || buffer!=c->playback_buffer || pcm!=c->decoded_pointer ||
                bytes!=c->frame.samples*2 || result<0 || result>bytes || result%2){c->invalid=true;return result;}
            auto* device=*reinterpret_cast<IDirectSoundBuffer**>(static_cast<char*>(buffer)+8);
            WAVEFORMATEX format{};DWORD written{},frequency{};
            if(!device || FAILED(device->GetFormat(&format,sizeof(format),&written)) || (written!=16 && written!=sizeof(format)) ||
                format.wFormatTag!=WAVE_FORMAT_PCM || format.nChannels!=1 || format.wBitsPerSample!=16 ||
                format.nBlockAlign!=2 || format.nSamplesPerSec<8000 || format.nSamplesPerSec>48000 ||
                format.nAvgBytesPerSec!=format.nSamplesPerSec*2 || format.cbSize || FAILED(device->GetFrequency(&frequency)) ||
                frequency<4000 || frequency>96000 || (received_rate && received_rate!=format.nSamplesPerSec)){c->invalid=true;return result;}
            received_rate=format.nSamplesPerSec;
            const auto observed_frequency=static_cast<unsigned>(frequency);
            frequency_min=frequency_min?(std::min)(frequency_min,observed_frequency):observed_frequency;
            frequency_max=(std::max)(frequency_max,observed_frequency);
            c->enqueued=true;c->frame.enqueued_bytes=result;
        }catch(...){c->invalid=true;}
    }
    return result;
}
void write_received_file(const std::wstring& path,const void* data,DWORD bytes) {
    const auto absolute=std::filesystem::path(path);
    if(!absolute.is_absolute())throw std::runtime_error("Received PCM absolute path required");
    for(auto part=absolute.parent_path();!part.empty();part=part.parent_path()){
        const auto attributes=GetFileAttributesW(part.c_str());
        if(attributes==INVALID_FILE_ATTRIBUTES || (attributes&FILE_ATTRIBUTE_REPARSE_POINT))throw std::runtime_error("Received PCM parent redirected/missing");
        if(part==part.parent_path())break;
    }
    HANDLE file=CreateFileW(path.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(file==INVALID_HANDLE_VALUE)throw std::runtime_error("Fresh received PCM output required");
    DWORD count{};const bool okay=WriteFile(file,data,bytes,&count,nullptr) && count==bytes && FlushFileBuffers(file);
    CloseHandle(file);if(!okay)throw std::runtime_error("Received PCM write failed");
}
void write_received_wave(const std::wstring& path,const std::vector<std::int16_t>& pcm) {
    const auto bytes=static_cast<std::uint32_t>(pcm.size()*2);
    std::vector<unsigned char> wav(44+bytes);auto put=[&](unsigned offset,std::uint32_t value,unsigned count){for(unsigned i=0;i<count;++i)wav[offset+i]=static_cast<unsigned char>(value>>(8*i));};
    std::memcpy(wav.data(),"RIFF",4);put(4,36+bytes,4);std::memcpy(wav.data()+8,"WAVEfmt ",8);
    put(16,16,4);put(20,1,2);put(22,1,2);put(24,received_rate,4);put(28,received_rate*2,4);
    put(32,2,2);put(34,16,2);std::memcpy(wav.data()+36,"data",4);put(40,bytes,4);
    if(bytes)std::memcpy(wav.data()+44,pcm.data(),bytes);
    write_received_file(path,wav.data(),static_cast<DWORD>(wav.size()));
}
void finish_received() noexcept {
    if(received_finished || !received_pcm)return;
    received_finished=true;
    try {
        if(received_rate && !received_pcm->decoded().empty()){
            write_received_wave(received_path+L"-decoded.wav",received_pcm->decoded());
            write_received_wave(received_path+L"-submitted.wav",received_pcm->submitted());
        }
        const auto* member=received_pcm->speaker_identity();
        const auto json=std::string("{\"Schema\":\"iw7.received-native-pcm/1\",\"PID\":")+std::to_string(received_scope.pid)+
            ",\"Nonce\":\""+received_scope.nonce+"\",\"Generation\":\""+received_scope.generation+"\",\"RecorderChallenge\":\""+received_scope.challenge+
            "\",\"ReceiverSlot\":"+std::to_string(received_scope.receiver_slot)+",\"SenderSlot\":"+std::to_string(received_scope.sender_slot)+
            ",\"AdmittedTick\":"+std::to_string(received_scope.admitted_tick)+",\"DeadlineTick\":"+std::to_string(received_scope.deadline_tick)+
            ",\"Failed\":"+(received_pcm->failed()?"true":"false")+",\"Frames\":"+std::to_string(received_pcm->frames())+
            ",\"DecodedBytes\":"+std::to_string(received_pcm->decoded_bytes())+",\"EnqueuedBytes\":"+std::to_string(received_pcm->enqueued_bytes())+
            ",\"TruncatedFrames\":"+std::to_string(received_pcm->truncated_frames())+",\"FormatRate\":"+std::to_string(received_rate)+
            ",\"FrequencyMin\":"+std::to_string(frequency_min)+",\"FrequencyMax\":"+std::to_string(frequency_max)+
            ",\"SpeakerUser\":"+std::to_string(member?member->user:0)+",\"SpeakerEpochLow\":"+std::to_string(member?member->epoch_low:0)+
            ",\"SpeakerEpochHigh\":"+std::to_string(member?member->epoch_high:0)+",\"InputSourceRead\":false,\"OriginalCallsForwarded\":true}\n";
        write_received_file(received_path+L".json",json.data(),static_cast<DWORD>(json.size()));
        console::info("[paris-voice-pair] PCM_CLOSED; pid=%lu; nonce=%s; gen=%s; challenge=%s; tick_ms=%llu; failed=%u; frames=%llu.\n",
            GetCurrentProcessId(),received_scope.nonce.c_str(),received_scope.generation.c_str(),received_scope.challenge.c_str(),GetTickCount64(),
            static_cast<unsigned>(received_pcm->failed()),received_pcm->frames());
    }catch(...){console::error("[paris-voice-pair] Received PCM closure failed pid=%lu; retain diagnostics.\n",GetCurrentProcessId());}
}
void received_tick(const voice_test_binding::observation& o,std::uint64_t tick) {
    if(!received_enabled || received_finished)return;
    voice_test_binding::arm_request request;
    if(received_pcm){
        if(read_request(request,true,L"iw7-mod/paris-voice-output.arm") &&
            voice_test_binding::admit_cancel(request,received_binding,state->scope.source_sha256,received_scope.challenge,tick))finish_received();
        return;
    }
    if(!read_request(request,false,L"iw7-mod/paris-voice-output.arm") ||
        !voice_test_binding::admit_arm(request,o,state->scope.source_sha256,tick))return;
    received_scope={GetCurrentProcessId(),o.relay_slot,1-o.relay_slot,o.nonce,o.protection_generation,request.recorder_challenge,tick,tick+15000};
    received_binding=o;received_pcm=std::make_unique<voice_pcm_witness::buffer>(received_scope);
    console::info("[paris-voice-pair] PCM_READY; pid=%lu; nonce=%s; gen=%s; challenge=%s; tick_ms=%llu; failed=%u.\n",
        GetCurrentProcessId(),o.nonce.c_str(),o.protection_generation.c_str(),received_scope.challenge.c_str(),tick,static_cast<unsigned>(received_pcm->failed()));
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
    finish_received();cancelled=true;if(control)control->cancel();
    if(state){std::lock_guard lock(state->mutex);state->cached={};}
    }catch(...){}
}
void received_playback(void* session,unsigned slot,const char* data,int bytes,
    std::uint64_t user,std::uint64_t epoch_low,std::uint64_t epoch_high,std::uint32_t sequence,unsigned frame_index) {
    std::lock_guard lifecycle_guard(lifecycle);
    received_frame_context context;
    const bool collect=received_enabled && received_pcm && !received_finished;
    const auto previous=received_context;
    if(collect){context.playback_buffer=*reinterpret_cast<void**>(0x1477A01C0+slot*sizeof(void*));context.invalid=previous!=nullptr;received_context=&context;}
    struct restore {received_frame_context* prior;~restore(){received_context=prior;}} restore_context{previous};
    utils::hook::invoke<void>(0x140D59620,session,static_cast<int>(slot),data,bytes,0);
    if(collect){
        // Invalid/missing callbacks make the in-memory witness fail without
        // changing native playback. The transport has already validated frames.
        if(context.invalid || !context.decoded || !context.enqueued)context.frame.samples=0;
        const auto finished_tick=GetTickCount64();
        received_pcm->append({slot,user,epoch_low,epoch_high,sequence,frame_index},context.frame,finished_tick,
            GetCurrentThreadId()==main_tid && received_fresh(finished_tick));
    }
}
bool talk_admitted() noexcept {
    try {
        std::lock_guard lifecycle_guard(lifecycle);
        if(GetCurrentThreadId()!=main_tid || !installed || cancelled || !armed || !state || !control)return false;
        const auto m=control->snapshot();
        return m.armed && !m.failed && fresh(state.get(),state->scope,GetTickCount64());
    }catch(...){return false;}
}
bool begin_source_after_native_talk(std::uint64_t tick) noexcept {
    try {
        std::lock_guard lifecycle_guard(lifecycle);
        if(GetCurrentThreadId()!=main_tid || !installed || cancelled || !armed || !state || !control)return false;
        const auto proof=paris_test_fixture::capture_protection();
        if(!proof.protected_now || !proof.ui_ready || !proof.talk_valid || !proof.talk_active ||
            proof.talk_key0!=224 || proof.talk_key1 || !fresh(state.get(),state->scope,GetTickCount64()) ||
            FAILED(control->begin_source(tick))){cancel();return false;}
        console::info("[paris-fake-capture] Source started after native PTT pid=%lu nonce=%s gen=%s slot=%u source_tick_ms=%llu tick_ms=%llu\n",
            GetCurrentProcessId(),state->scope.client_nonce.c_str(),state->scope.server_generation.c_str(),state->scope.slot,tick,GetTickCount64());
        return true;
    }catch(...){cancel();return false;}
}
void observe_native_encoder() noexcept {
    try {
        std::lock_guard lifecycle_guard(lifecycle);
        if(codec_observed || !installed || cancelled || !armed || !state || !control || GetCurrentThreadId()!=main_tid ||
            !control->snapshot().source_started || !fresh(state.get(),state->scope,GetTickCount64()))return;
        auto* encoder=*reinterpret_cast<void**>(0x145D5C6E8);if(!encoder)return;
        const int quality=*reinterpret_cast<const int*>(0x1415062D8),cached=*reinterpret_cast<const int*>(0x141BB2C7C);
        const int mode=*reinterpret_cast<const int*>(static_cast<const char*>(encoder)+0x174);
        int vad{},dtx{},vbr{},abr{};
        for(const auto request:{31,35,13,33}){
            int* output=request==31?&vad:request==35?&dtx:request==13?&vbr:&abr;
            if(utils::hook::invoke<int>(0x1405E9520,encoder,request,output))return;
        }
        if(quality<0 || quality>10 || cached<0 || cached>10 || mode<0 || mode>8)return;
        codec_observed=true;
        console::info("[paris-voice-pair] CODEC; pid=%lu; nonce=%s; gen=%s; tick_ms=%llu; quality=%d; cached_quality=%d; configured_mode=%d; vad=%d; dtx=%d; vbr=%d; abr=%d; controls_written=0.\n",
            GetCurrentProcessId(),state->scope.client_nonce.c_str(),state->scope.server_generation.c_str(),GetTickCount64(),quality,cached,mode,vad,dtx,vbr,abr);
    }catch(...){}
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
            console::info("[paris-fake-capture] Observed pid=%lu tick_ms=%llu prepared=%u armed=%u failed=%u buffer_started=%u locked=%u source_started=%u source_tick_ms=%llu rate=%u channels=%u bits=%u align=%u buffer_bytes=%u source_frames=%llu published_frames=%llu source_output_frames=%llu nonzero_frames=%llu lock_calls=%llu lock_bytes=%llu lock_nonzero_bytes=%llu prepared_lock_bytes=%llu unlock_calls=%llu unlock_bytes=%llu\n",
                GetCurrentProcessId(),report_tick,static_cast<unsigned>(m.prepared),static_cast<unsigned>(m.armed),static_cast<unsigned>(m.failed),static_cast<unsigned>(m.buffer_started),static_cast<unsigned>(m.buffer_locked),
                static_cast<unsigned>(m.source_started),m.source_start_tick,m.rate,m.channels,m.bits,m.block_align,m.buffer_bytes,m.source_frames,m.published_frames,m.published_source_frames,m.published_nonzero_frames,
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
        if(received_pcm && !received_finished && (received_pcm->failed() || tick<received_scope.admitted_tick ||
            tick>=received_scope.deadline_tick || !voice_test_binding::current(o,tick) || !voice_test_binding::same(received_binding,o))){
            received_pcm->invalidate();finish_received();
        }
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
        received_tick(o,tick);
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
        if(std::wcsstr(GetCommandLineW(),L"-paris-fake-capture-") || utils::flags::has_flag("paris-voice-received-pcm") ||
            std::wcsstr(GetCommandLineW(),L"-paris-voice-received-output="))throw std::runtime_error("Orphan fake/received capture selectors refused");
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
    if(std::memcmp(reinterpret_cast<const void*>(0x1405E9520),"\x48\x8b\x01\x48\xff\x60\x50",7))throw std::runtime_error("Native codec getter signature differs");
    a.requested=a.isolated_build=a.isolated_flag=a.client_test_flag=a.voice_test_flag=true;
    a.marker_verified=a.owned_identity=a.signatures_verified=a.capture_owner_absent=a.volume_owner_absent=true;
    a.process_id=GetCurrentProcessId();a.admitted_tick=GetTickCount64();a.deadline_tick=a.admitted_tick+120000;
    state=p;installed=true;
    received_enabled=utils::flags::has_flag("paris-voice-received-pcm");
    if(received_enabled){
        if(utils::flags::has_flag("paris-voice-native-trace") ||
            std::memcmp(reinterpret_cast<const void*>(0x140B79310),"\x48\x89\x5c\x24\x20\x57\xb8\x30\x40\x00\x00",11) ||
            std::memcmp(reinterpret_cast<const void*>(0x140B79B60),"\x48\x89\x5c\x24\x10\x56\x48\x83\xec\x60",10) ||
            std::memcmp(reinterpret_cast<const void*>(0x140D59620),"\x40\x55\x57\x41\x54\x41\x56\x41\x57\xb8\x40\x20\x00\x00",14) ||
            std::memcmp(reinterpret_cast<const void*>(0x140D596F0),"\x44\x8b\x0d\xe5\x2f\x00\x05\x4c\x8d\x44\x24\x20\x8b\xfd\x48\x63\xcb\x2b\xfb\x41\x3b\xf9\x41\x0f\x4d\xf9\x49\x03\xcf\x8b\xd7\xe8\xfc\xfb\xe1\xff\x8b\xf0\x85\xc0\x7e\x15\x4b\x8b\x8c\xf4\xc0\x01\x7a\x07\x48\x8d\x54\x24\x20\x44\x8b\xc0\xe8\xa1\xff\xe1\xff",63) ||
            std::memcmp(reinterpret_cast<const void*>(0x140B796D0),"\xe9\x8b\x04\x00\x00",5) ||
            std::memcmp(reinterpret_cast<const void*>(0x140B79B99),"\x8b\x41\x10\x2b\x41\x2c\x44\x3b\xc0\x44\x0f\x4d\xc0\x45\x85\xc0\x74\xe1\x48\x8b\x49\x08",22))
            throw std::runtime_error("Received PCM forwarding signatures/owner differ");
        received_path=argument(L"-paris-voice-received-output=");
        if(!std::filesystem::path(received_path).is_absolute())throw std::runtime_error("Received PCM absolute output required");
        received_decode_hook.create(0x140B79310,received_decode);received_enqueue_hook.create(0x140B79B60,received_enqueue);
    }
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
