#include "voice_test_capture.hpp"
#include <bcrypt.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "dxguid.lib")
#pragma comment(lib, "uuid.lib")

namespace voice_test_capture
{
namespace
{
bool hex(const std::string& s, std::size_t count) noexcept
{
    if (s.size()!=count) return false;
    for (char c:s) if (!((c>='0' && c<='9') || (c>='a' && c<='f'))) return false;
    return s.find_first_not_of('0')!=std::string::npos;
}
unsigned u16(const unsigned char* p) { return p[0] | unsigned(p[1])<<8; }
std::uint32_t u32(const unsigned char* p) { return p[0] | std::uint32_t(p[1])<<8 | std::uint32_t(p[2])<<16 | std::uint32_t(p[3])<<24; }
std::vector<short> parse(const std::vector<unsigned char>& b)
{
    if (b.size()<44 || b.size()>480102 || std::memcmp(b.data(),"RIFF",4) || std::memcmp(b.data()+8,"WAVE",4) || u32(b.data()+4)!=b.size()-8) throw std::runtime_error("RIFF bound");
    bool fmt=false,data=false; std::vector<short> pcm;
    for (std::size_t i=12;i<b.size();)
    {
        if (b.size()-i<8) throw std::runtime_error("chunk header");
        const auto n=u32(b.data()+i+4); const auto* p=b.data()+i+8;
        if (n>b.size()-i-8) throw std::runtime_error("chunk bound");
        if (!std::memcmp(b.data()+i,"fmt ",4))
        {
            if (fmt || (n!=16 && n!=18) || u16(p)!=1 || u16(p+2)!=1 || u32(p+4)!=16000 || u32(p+8)!=32000 || u16(p+12)!=2 || u16(p+14)!=16 || (n==18 && u16(p+16))) throw std::runtime_error("PCM16 mono 16k required");
            fmt=true;
        }
        else if (!std::memcmp(b.data()+i,"data",4))
        {
            if (!fmt || data || !n || n%2 || n>480000) throw std::runtime_error("data bound");
            pcm.resize(n/2); for (std::size_t j=0;j<pcm.size();++j) pcm[j]=static_cast<short>(u16(p+j*2)); data=true;
        }
        const auto next=i+8+n+(n&1u); if (next>b.size()) throw std::runtime_error("pad bound"); i=next;
    }
    if (!fmt || !data) throw std::runtime_error("missing chunk"); return pcm;
}
bool digest(const std::vector<unsigned char>& b, const std::string& expected)
{
    BCRYPT_ALG_HANDLE alg{}; BCRYPT_HASH_HANDLE hash{};
    struct cleanup { BCRYPT_ALG_HANDLE& a; BCRYPT_HASH_HANDLE& h; ~cleanup(){if(h) BCryptDestroyHash(h);if(a) BCryptCloseAlgorithmProvider(a,0);} } guard{alg,hash};
    if (BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0) return false;
    DWORD size{},written{};
    if (BCryptGetProperty(alg,BCRYPT_OBJECT_LENGTH,reinterpret_cast<PUCHAR>(&size),sizeof(size),&written,0)<0 || size>65536) return false;
    std::vector<unsigned char> object(size); unsigned char result[32]{};
    if (BCryptCreateHash(alg,&hash,object.data(),size,nullptr,0,0)<0 || BCryptHashData(hash,const_cast<PUCHAR>(b.data()),static_cast<ULONG>(b.size()),0)<0 || BCryptFinishHash(hash,result,32,0)<0) return false;
    const char alphabet[]="0123456789abcdef"; char actual[64]{};
    for(unsigned i=0;i<32;++i){actual[i*2]=alphabet[result[i]>>4];actual[i*2+1]=alphabet[result[i]&15];}
    return expected.size()==64 && std::memcmp(actual,expected.data(),64)==0;
}
enum class phase { prepared, armed, failed };
bool prepared_permitted(const admission& a,std::uint64_t now) noexcept
{
    return a.requested && a.isolated_build && a.isolated_flag && a.client_test_flag &&
        a.voice_test_flag && a.marker_verified && a.owned_identity && a.signatures_verified &&
        a.capture_owner_absent && a.volume_owner_absent && a.process_id &&
        a.server_port>=27100 && a.server_port<=27999 && a.slot<=1 && hex(a.source_sha256,64) &&
        a.client_nonce.empty() && a.server_generation.empty() &&
        a.deadline_tick>a.admitted_tick && a.deadline_tick-a.admitted_tick<=120000 &&
        now>=a.admitted_tick && now<a.deadline_tick;
}
struct state final : control
{
    admission gate; environment env; std::vector<short> pcm;
    std::mutex mutex;
    phase current=phase::armed;
    std::atomic<bool> failed{false};
    bool buffer_created{},buffer_started{},buffer_locked{};
    std::uint64_t last_check{};
    statistics stats;
    statistics snapshot() noexcept override
    {
        try {
            std::lock_guard<std::mutex> guard(mutex);auto result=stats;
            result.failed=failed.load() || current==phase::failed;
            result.prepared=!result.failed && current==phase::prepared;result.armed=!result.failed && current==phase::armed;
            result.buffer_created=buffer_created;result.buffer_started=buffer_started;result.buffer_locked=buffer_locked;
            result.source_frames=pcm.size();return result;
        }catch(...){statistics result;result.failed=true;return result;}
    }
    // Caller holds mutex; callbacks must not reenter this COM/control object.
    bool check(std::uint64_t& now) noexcept
    {
        if (failed || !env.now || !env.fresh) return false;
        now=env.now(env.opaque);
        if(now<last_check){failed=true;current=phase::failed;return false;}last_check=now;
        const bool valid=current==phase::prepared ? prepared_permitted(gate,now) :
            permitted(gate,now) && env.fresh(env.opaque,gate,now);
        if (!valid) {failed=true;current=phase::failed;return false;}
        return true;
    }
    HRESULT arm(const admission& active) noexcept override
    {
        try
        {
            std::lock_guard<std::mutex> guard(mutex);
            std::uint64_t now{};
            if (current!=phase::prepared || !check(now)) return DSERR_INVALIDCALL;
            if (!buffer_started || buffer_locked) return DSERR_INVALIDCALL;
            if (!permitted(active,now) || active.process_id!=gate.process_id ||
                active.server_port!=gate.server_port || active.slot!=gate.slot || active.source_sha256!=gate.source_sha256 ||
                now-active.admitted_tick>500 || !env.fresh(env.opaque,active,now))
            {failed=true;current=phase::failed;return DSERR_NODRIVER;}
            gate=active;gate.admitted_tick=now;current=phase::armed;return S_OK;
        }catch(...){failed=true;return E_FAIL;}
    }
    HRESULT begin_source(std::uint64_t tick) noexcept override
    {
        try {
            std::lock_guard<std::mutex> guard(mutex);std::uint64_t now{};
            if(current!=phase::armed || !check(now) || stats.source_started || !buffer_started || buffer_locked)return DSERR_INVALIDCALL;
            if(tick<gate.admitted_tick || tick>now || now-tick>500){failed=true;current=phase::failed;return DSERR_NODRIVER;}
            stats.source_started=true;stats.source_start_tick=tick;return S_OK;
        }catch(...){failed=true;return E_FAIL;}
    }
    void cancel() noexcept override
    {
        try{std::lock_guard<std::mutex> guard(mutex);failed=true;current=phase::failed;}catch(...){}
    }
};
class buffer final : public IDirectSoundCaptureBuffer
{
    std::atomic<ULONG> refs{1}; std::shared_ptr<state> shared;
    WAVEFORMATEX format{}; std::vector<unsigned char> ring;
    bool running{},started{},locked{},armed_started{}; std::uint64_t start{},last{},frames{},consumed{};
    DWORD cursor{},read_cursor{},lock_bytes{},first_bytes{},second_bytes{}; void* first{};void* second{};
    bool check(std::uint64_t& now) noexcept
    {
        if (!shared->check(now) || (started && now<last) || (running && shared->current==phase::armed && now-last>500 && armed_started)) {shared->failed=true;running=false;return false;} return true;
    }
public:
    buffer(std::shared_ptr<state> s,const DSCBUFFERDESC& d):shared(std::move(s)),format(*d.lpwfxFormat),ring(d.dwBufferBytes)
    {
        // Constructor runs with the shared mutex held by CreateCaptureBuffer.
        shared->stats.descriptor_bytes=d.dwSize;shared->stats.descriptor_flags=d.dwFlags;
        shared->stats.rate=format.nSamplesPerSec;shared->stats.channels=format.nChannels;
        shared->stats.bits=format.wBitsPerSample;shared->stats.block_align=format.nBlockAlign;
        shared->stats.buffer_bytes=d.dwBufferBytes;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id,void** p) override
    {if(!p)return E_POINTER;*p=nullptr;if(id!=IID_IUnknown && id!=IID_IDirectSoundCaptureBuffer)return E_NOINTERFACE;*p=static_cast<IDirectSoundCaptureBuffer*>(this);AddRef();return S_OK;}
    ULONG STDMETHODCALLTYPE AddRef() override {return ++refs;}
    ULONG STDMETHODCALLTYPE Release() override {const auto n=--refs;if(!n)delete this;return n;}
    HRESULT STDMETHODCALLTYPE GetCaps(LPDSCBCAPS c) override
    {if(!c || c->dwSize!=sizeof(*c))return DSERR_INVALIDPARAM;c->dwFlags=0;c->dwBufferBytes=static_cast<DWORD>(ring.size());c->dwReserved=0;return S_OK;}
    HRESULT STDMETHODCALLTYPE GetCurrentPosition(LPDWORD capture,LPDWORD read) override
    {
        if(capture)*capture=0;if(read)*read=0;
        try
        {
            std::lock_guard<std::mutex> guard(shared->mutex);std::uint64_t now{};
            if(!check(now))return DSERR_NODRIVER;if(locked)return DSERR_INVALIDCALL;
            if(shared->current==phase::prepared) return S_OK;
            if(running && !armed_started){start=last=shared->gate.admitted_tick;armed_started=true;}
            if(running)
            {
                const auto next=(now-start)*format.nSamplesPerSec/1000;
                // Refuse lost polling/overwrite instead of silently skipping PCM.
                if(now-last>500 || next<frames || (next-consumed)*format.nBlockAlign>=ring.size()) {shared->failed=true;running=false;return DSERR_NODRIVER;}
                for(auto f=frames;f<next;++f)
                {
                    const auto origin=shared->stats.source_started ?
                        (shared->stats.source_start_tick-shared->gate.admitted_tick)*format.nSamplesPerSec/1000 : UINT64_MAX;
                    const double pos=f>=origin ? static_cast<double>(f-origin)*16000/format.nSamplesPerSec :
                        static_cast<double>(shared->pcm.size());
                    const auto index=static_cast<std::size_t>(pos);short value{};
                    if(index<shared->pcm.size())
                    {
                        ++shared->stats.published_source_frames;
                        const auto adjacent=(std::min)(index+1,shared->pcm.size()-1);
                        value=static_cast<short>(shared->pcm[index]+(shared->pcm[adjacent]-shared->pcm[index])*(pos-static_cast<double>(index)));
                    }
                    ++shared->stats.published_frames;
                    if(value)++shared->stats.published_nonzero_frames;
                    const auto offset=static_cast<std::size_t>(f*format.nBlockAlign%ring.size());
                    for(unsigned channel=0;channel<format.nChannels;++channel)std::memcpy(ring.data()+offset+channel*2,&value,2);
                }
                frames=next;last=now;cursor=static_cast<DWORD>(frames*format.nBlockAlign%ring.size());
            }
            if(capture)*capture=cursor;if(read)*read=cursor;return S_OK;
        } catch(...){shared->failed=true;return E_FAIL;}
    }
    HRESULT STDMETHODCALLTYPE GetFormat(LPWAVEFORMATEX f,DWORD size,LPDWORD written) override
    {if(written)*written=sizeof(format);if(!f)return size==0 ? S_OK:DSERR_INVALIDPARAM;if(size<sizeof(format))return DSERR_INVALIDPARAM;std::memcpy(f,&format,sizeof(format));return S_OK;}
    HRESULT STDMETHODCALLTYPE GetStatus(LPDWORD p) override
    {if(!p)return E_POINTER;*p=0;try{std::lock_guard<std::mutex> guard(shared->mutex);std::uint64_t now{};if(!check(now))return DSERR_NODRIVER;if(running)*p=DSCBSTATUS_CAPTURING|DSCBSTATUS_LOOPING;return S_OK;}catch(...){return E_FAIL;}}
    HRESULT STDMETHODCALLTYPE Initialize(LPDIRECTSOUNDCAPTURE,LPCDSCBUFFERDESC) override {return DSERR_ALREADYINITIALIZED;}
    HRESULT STDMETHODCALLTYPE Lock(DWORD offset,DWORD bytes,LPVOID* p1,LPDWORD n1,LPVOID* p2,LPDWORD n2,DWORD flags) override
    {
        if(p1)*p1=nullptr;if(n1)*n1=0;if(p2)*p2=nullptr;if(n2)*n2=0;
        try
        {
            std::lock_guard<std::mutex> guard(shared->mutex);std::uint64_t now{};if(!check(now))return DSERR_NODRIVER;
            if(!p1 || !n1 || !p2 || !n2 || flags || locked || !running || !bytes || offset!=read_cursor || offset>=ring.size() || bytes>ring.size() || bytes%format.nBlockAlign || (shared->current==phase::armed && bytes>(frames-consumed)*format.nBlockAlign))return DSERR_INVALIDPARAM;
            if(shared->current==phase::prepared)std::fill(ring.begin(),ring.end(),static_cast<unsigned char>(0));
            first_bytes=(std::min)(bytes,static_cast<DWORD>(ring.size())-offset);second_bytes=bytes-first_bytes;
            first=ring.data()+offset;second=second_bytes ? ring.data():nullptr;lock_bytes=bytes;locked=true;shared->buffer_locked=true;
            ++shared->stats.lock_calls;shared->stats.lock_bytes+=bytes;
            if(shared->current==phase::prepared)shared->stats.prepared_lock_bytes+=bytes;
            for(DWORD i=0;i<first_bytes;++i)if(static_cast<const unsigned char*>(first)[i])++shared->stats.lock_nonzero_bytes;
            for(DWORD i=0;i<second_bytes;++i)if(static_cast<const unsigned char*>(second)[i])++shared->stats.lock_nonzero_bytes;
            *p1=first;*n1=first_bytes;*p2=second;*n2=second_bytes;return S_OK;
        }catch(...){shared->failed=true;return E_FAIL;}
    }
    HRESULT STDMETHODCALLTYPE Start(DWORD flags) override
    {
        try{std::lock_guard<std::mutex> guard(shared->mutex);std::uint64_t now{};if(!check(now))return DSERR_NODRIVER;if(flags!=DSCBSTART_LOOPING || started)return DSERR_INVALIDCALL;start=last=now;running=started=true;shared->buffer_started=true;armed_started=shared->current==phase::armed;return S_OK;}catch(...){shared->failed=true;return E_FAIL;}
    }
    HRESULT STDMETHODCALLTYPE Stop() override
    {try{std::lock_guard<std::mutex> guard(shared->mutex);running=false;shared->buffer_started=false;return S_OK;}catch(...){return E_FAIL;}}
    HRESULT STDMETHODCALLTYPE Unlock(LPVOID p1,DWORD n1,LPVOID p2,DWORD n2) override
    {
        try{std::lock_guard<std::mutex> guard(shared->mutex);if(!locked || p1!=first || p2!=second || n1!=first_bytes || n2!=second_bytes)return DSERR_INVALIDPARAM;
            ++shared->stats.unlock_calls;shared->stats.unlock_bytes+=lock_bytes;
            if(shared->current==phase::armed){consumed+=lock_bytes/format.nBlockAlign;read_cursor=static_cast<DWORD>(consumed*format.nBlockAlign%ring.size());}locked=false;shared->buffer_locked=false;first=second=nullptr;return S_OK;}catch(...){shared->failed=true;return E_FAIL;}
    }
};
class device final : public IDirectSoundCapture
{
    std::atomic<ULONG> refs{1};std::shared_ptr<state> shared;
public:
    explicit device(std::shared_ptr<state> s):shared(std::move(s)){}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id,void** p) override
    {if(!p)return E_POINTER;*p=nullptr;if(id!=IID_IUnknown && id!=IID_IDirectSoundCapture)return E_NOINTERFACE;*p=static_cast<IDirectSoundCapture*>(this);AddRef();return S_OK;}
    ULONG STDMETHODCALLTYPE AddRef() override{return ++refs;}
    ULONG STDMETHODCALLTYPE Release() override{const auto n=--refs;if(!n)delete this;return n;}
    HRESULT STDMETHODCALLTYPE CreateCaptureBuffer(LPCDSCBUFFERDESC d,LPDIRECTSOUNDCAPTUREBUFFER* output,LPUNKNOWN outer) override
    {
        if(!output)return E_POINTER;*output=nullptr;
        try
        {
            std::lock_guard<std::mutex> guard(shared->mutex);
            std::uint64_t now{};if(!shared->check(now))return DSERR_NODRIVER;
            if(!d || outer || d->dwSize!=sizeof(*d) || d->dwFlags || d->dwReserved || d->dwFXCount || d->lpDSCFXDesc || !d->lpwfxFormat)return DSERR_INVALIDPARAM;
            const auto& f=*d->lpwfxFormat;
            if(f.wFormatTag!=WAVE_FORMAT_PCM || f.wBitsPerSample!=16 || f.cbSize || f.nChannels<1 || f.nChannels>2 || f.nSamplesPerSec<8000 || f.nSamplesPerSec>48000 || f.nBlockAlign!=f.nChannels*2 || f.nAvgBytesPerSec!=f.nSamplesPerSec*f.nBlockAlign || d->dwBufferBytes<4096 || d->dwBufferBytes>131072 || d->dwBufferBytes%f.nBlockAlign)return DSERR_BADFORMAT;
            if(shared->buffer_created)return DSERR_ALLOCATED;shared->buffer_created=true;
            try{*output=new buffer(shared,*d);}catch(...){shared->failed=true;throw;}return S_OK;
        }catch(...){return E_FAIL;}
    }
    HRESULT STDMETHODCALLTYPE GetCaps(LPDSCCAPS c) override
    {if(!c || c->dwSize!=sizeof(*c))return DSERR_INVALIDPARAM;c->dwFlags=0;c->dwFormats=0;c->dwChannels=2;return S_OK;}
    HRESULT STDMETHODCALLTYPE Initialize(LPCGUID) override{return DSERR_ALREADYINITIALIZED;}
};
}
bool permitted(const admission& a,std::uint64_t now) noexcept
{
    return a.requested && a.isolated_build && a.isolated_flag && a.client_test_flag && a.voice_test_flag && a.marker_verified && a.owned_identity && a.signatures_verified && a.capture_owner_absent && a.volume_owner_absent && a.process_id && a.server_port>=27100 && a.server_port<=27999 && a.slot<=1 && hex(a.client_nonce,32) && hex(a.server_generation,32) && hex(a.source_sha256,64) && now>=a.admitted_tick && a.deadline_tick>a.admitted_tick && a.deadline_tick-a.admitted_tick<=30000 && now<a.deadline_tick;
}
HRESULT prepare(const admission& scope,const environment& env,const std::vector<unsigned char>& wav,
    IDirectSoundCapture** output,std::shared_ptr<control>* controller) noexcept
{
    if(output)*output=nullptr;if(controller)controller->reset();
    if(!output || !controller)return E_POINTER;
    try
    {
        if(!env.owner || env.owner.get()!=env.opaque || !env.now || !env.fresh)return DSERR_INVALIDPARAM;
        const auto prepared_now=env.now(env.opaque);
        if(!prepared_permitted(scope,prepared_now) || wav.size()<44 ||
            wav.size()>480102 || !digest(wav,scope.source_sha256))return DSERR_INVALIDPARAM;
        auto value=std::make_shared<state>();value->gate=scope;value->env=env;
        value->pcm=parse(wav);value->current=phase::prepared;value->last_check=prepared_now;
        *output=new device(value);*controller=value;return S_OK;
    }catch(...){return E_FAIL;}
}
HRESULT create(const admission& gate,const environment& env,const std::vector<unsigned char>& wav,IDirectSoundCapture** output) noexcept
{
    if(!output)return E_POINTER;*output=nullptr;
    try
    {
        if(!env.now || !env.fresh || !permitted(gate,env.now(env.opaque)) || wav.size()<44 || wav.size()>480102 || !digest(wav,gate.source_sha256))return DSERR_INVALIDPARAM;
        auto value=std::make_shared<state>();value->gate=gate;value->env=env;value->pcm=parse(wav);
        value->stats.source_started=true;value->stats.source_start_tick=gate.admitted_tick;
        std::uint64_t now{};if(!value->check(now))return DSERR_NODRIVER;*output=new device(std::move(value));return S_OK;
    }catch(...){return E_FAIL;}
}
}
