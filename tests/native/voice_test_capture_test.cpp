#include "../../src/native/voice_test_capture.hpp"
#include <cassert>
#include <cstring>
#include <iostream>
#include <bcrypt.h>
#include <thread>
using namespace voice_test_capture;
struct clock_state { std::uint64_t tick=1000;bool protected_now=true; };
std::uint64_t now(void* p) noexcept {return static_cast<clock_state*>(p)->tick;}
bool fresh(void* p,const admission& a,std::uint64_t) noexcept
{return static_cast<clock_state*>(p)->protected_now && a.client_nonce=="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" && a.server_generation=="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";}
void put16(std::vector<unsigned char>& b,std::size_t i,unsigned v){b[i]=static_cast<unsigned char>(v);b[i+1]=static_cast<unsigned char>(v>>8);}
void put32(std::vector<unsigned char>& b,std::size_t i,unsigned v){put16(b,i,v);put16(b,i+2,v>>16);}
std::vector<unsigned char> wave()
{
    std::vector<unsigned char> b(16044);std::memcpy(b.data(),"RIFF",4);put32(b,4,16036);std::memcpy(b.data()+8,"WAVEfmt ",8);put32(b,16,16);put16(b,20,1);put16(b,22,1);put32(b,24,16000);put32(b,28,32000);put16(b,32,2);put16(b,34,16);std::memcpy(b.data()+36,"data",4);put32(b,40,16000);for(std::size_t i=44;i<b.size();i+=2)put16(b,i,1000);return b;
}
std::string sha(const std::vector<unsigned char>& bytes)
{
    BCRYPT_ALG_HANDLE alg{};assert(BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,nullptr,0)>=0);
    unsigned char result[32]{};assert(BCryptHash(alg,nullptr,0,const_cast<PUCHAR>(bytes.data()),static_cast<ULONG>(bytes.size()),result,32)>=0);BCryptCloseAlgorithmProvider(alg,0);
    std::string value;const char alphabet[]="0123456789abcdef";for(auto b:result){value.push_back(alphabet[b>>4]);value.push_back(alphabet[b&15]);}return value;
}
admission gate()
{
    admission a;a.requested=a.isolated_build=a.isolated_flag=a.client_test_flag=a.voice_test_flag=a.marker_verified=a.owned_identity=a.signatures_verified=a.capture_owner_absent=a.volume_owner_absent=true;a.process_id=123;a.server_port=27120;a.client_nonce=std::string(32,'a');a.server_generation=std::string(32,'b');a.source_sha256="d6562284957991803328564d8eea3102b94635b8ca4c8863412117bb030ba73f";a.admitted_tick=1000;a.deadline_tick=30000;return a;
}
IDirectSoundCaptureBuffer* setup(clock_state& c,IDirectSoundCapture*& device)
{
    environment e{&c,{},now,fresh};assert(SUCCEEDED(create(gate(),e,wave(),&device)));
    WAVEFORMATEX f{WAVE_FORMAT_PCM,1,16000,32000,2,16,0};DSCBUFFERDESC d{};d.dwSize=sizeof(d);d.dwBufferBytes=8192;d.lpwfxFormat=&f;
    IDirectSoundCaptureBuffer* b{};assert(SUCCEEDED(device->CreateCaptureBuffer(&d,&b,nullptr)));IDirectSoundCaptureBuffer* duplicate=reinterpret_cast<IDirectSoundCaptureBuffer*>(1);assert(FAILED(device->CreateCaptureBuffer(&d,&duplicate,nullptr)) && !duplicate);assert(SUCCEEDED(b->Start(DSCBSTART_LOOPING)));assert(FAILED(b->Start(DSCBSTART_LOOPING)));return b;
}
int main()
{
    auto a=gate();assert(permitted(a,1000));assert(!permitted(a,999));assert(!permitted(a,30000));a.server_port=27016;assert(!permitted(a,1000));a=gate();a.volume_owner_absent=false;assert(!permitted(a,1000));a=gate();a.client_nonce[0]='X';assert(!permitted(a,1000));a=gate();a.deadline_tick=31001;assert(!permitted(a,1000));
    clock_state c;environment e{&c,{},now,fresh};IDirectSoundCapture* dev=reinterpret_cast<IDirectSoundCapture*>(1);auto bytes=wave();bytes[44]^=1;assert(FAILED(create(gate(),e,bytes,&dev)) && !dev);
    bytes=wave();bytes[34]=8;a=gate();a.source_sha256=sha(bytes);assert(FAILED(create(a,e,bytes,&dev)) && !dev);
    bytes=wave();bytes.pop_back();a=gate();a.source_sha256=sha(bytes);assert(FAILED(create(a,e,bytes,&dev)) && !dev);
    c.protected_now=false;assert(FAILED(create(gate(),e,wave(),&dev)) && !dev);c.protected_now=true;
    auto* b=setup(c,dev);void* unsupported=reinterpret_cast<void*>(1);assert(b->QueryInterface(IID_IDirectSoundCaptureBuffer8,&unsupported)==E_NOINTERFACE && !unsupported);
    DWORD capture{},read{};c.tick=1100;assert(SUCCEEDED(b->GetCurrentPosition(&capture,&read)) && read==3200 && capture==read);
    void* p1{};void* p2{};DWORD n1{},n2{};assert(FAILED(b->Lock(0,3202,&p1,&n1,&p2,&n2,0)));assert(!p1 && !p2 && !n1 && !n2);
    assert(SUCCEEDED(b->Lock(0,3200,&p1,&n1,&p2,&n2,0)));assert(n1==3200 && n2==0 && static_cast<short*>(p1)[0]==1000);assert(FAILED(b->GetCurrentPosition(&capture,&read)));assert(FAILED(b->Unlock(p1,n1-2,p2,n2)));assert(SUCCEEDED(b->Unlock(p1,n1,p2,n2)));
    c.tick=1200;assert(SUCCEEDED(b->GetCurrentPosition(&capture,&read)) && read==6400);assert(SUCCEEDED(b->Lock(3200,3200,&p1,&n1,&p2,&n2,0)));assert(SUCCEEDED(b->Unlock(p1,n1,p2,n2)));
    c.tick=1300;assert(SUCCEEDED(b->GetCurrentPosition(&capture,&read)) && read==1408);assert(SUCCEEDED(b->Lock(6400,3200,&p1,&n1,&p2,&n2,0)));assert(n1==1792 && n2==1408);assert(static_cast<short*>(p2)[0]==1000);assert(SUCCEEDED(b->Unlock(p1,n1,p2,n2)));
    c.protected_now=false;assert(b->GetCurrentPosition(&capture,&read)==DSERR_NODRIVER && !read);c.protected_now=true;assert(b->GetCurrentPosition(&capture,&read)==DSERR_NODRIVER);assert(SUCCEEDED(b->Stop()));b->Release();dev->Release();
    c={};b=setup(c,dev);c.tick=999;assert(b->GetCurrentPosition(&capture,&read)==DSERR_NODRIVER);b->Release();dev->Release();
    c={};b=setup(c,dev);c.tick=1501;assert(b->GetCurrentPosition(&capture,&read)==DSERR_NODRIVER);b->Release();dev->Release();
    c={};b=setup(c,dev);c.tick=1100;assert(SUCCEEDED(b->GetCurrentPosition(&capture,&read)));c.tick=1601;assert(b->Lock(0,3200,&p1,&n1,&p2,&n2,0)==DSERR_NODRIVER && !p1 && !n1);b->Release();dev->Release();
    c={};b=setup(c,dev);c.tick=1260;assert(b->GetCurrentPosition(&capture,&read)==DSERR_NODRIVER);b->Release();dev->Release();
    c={};b=setup(c,dev);c.tick=30000;assert(b->GetCurrentPosition(&capture,&read)==DSERR_NODRIVER);b->Release();dev->Release();
    // Separate prepared object: complete normal COM startup without a connection.
    auto provider=std::make_shared<clock_state>();provider->protected_now=false;
    std::weak_ptr<clock_state> weak=provider;
    environment owned{provider.get(),provider,now,fresh};
    auto prep=gate();prep.client_nonce.clear();prep.server_generation.clear();prep.deadline_tick=121000;
    std::shared_ptr<control> controller;
    assert(SUCCEEDED(prepare(prep,owned,wave(),&dev,&controller)));
    auto metrics=controller->snapshot();assert(metrics.prepared && !metrics.armed && !metrics.failed && !metrics.buffer_created && metrics.source_frames==8000);
    // Readonly observation must not sample an invalid clock or change admission.
    provider->tick=999;metrics=controller->snapshot();assert(metrics.prepared && !metrics.failed);provider->tick=1000;
    WAVEFORMATEX pf{WAVE_FORMAT_PCM,1,16000,32000,2,16,0};
    DSCBUFFERDESC pd{};pd.dwSize=sizeof(pd);pd.dwBufferBytes=8192;pd.lpwfxFormat=&pf;
    b=nullptr;assert(SUCCEEDED(dev->CreateCaptureBuffer(&pd,&b,nullptr)));
    metrics=controller->snapshot();assert(metrics.buffer_created && metrics.descriptor_bytes==sizeof(pd) && !metrics.descriptor_flags &&
        metrics.rate==16000 && metrics.channels==1 && metrics.bits==16 && metrics.block_align==2 && metrics.buffer_bytes==8192);
    assert(SUCCEEDED(b->Start(DSCBSTART_LOOPING)));
    assert(FAILED(controller->begin_source(1000)));
    provider->tick=6000;assert(SUCCEEDED(b->GetCurrentPosition(&capture,&read)) && capture==0 && read==0);
    assert(SUCCEEDED(b->Lock(0,3200,&p1,&n1,&p2,&n2,0)));
    metrics=controller->snapshot();assert(metrics.prepared && metrics.buffer_locked && metrics.lock_calls==1 && metrics.lock_bytes==3200 &&
        metrics.prepared_lock_bytes==3200 && !metrics.lock_nonzero_bytes && !metrics.published_frames);
    for(DWORD i=0;i<n1;++i)assert(static_cast<unsigned char*>(p1)[i]==0);
    auto active=gate();active.admitted_tick=6000;active.deadline_tick=36000;
    provider->protected_now=true;
    HRESULT locked_arm=S_OK;
    std::thread blocked([&]{locked_arm=controller->arm(active);});blocked.join();
    assert(FAILED(locked_arm));assert(static_cast<short*>(p1)[0]==0);
    assert(SUCCEEDED(b->Unlock(p1,n1,p2,n2)));
    assert(SUCCEEDED(controller->arm(active)));assert(FAILED(controller->arm(active)));
    metrics=controller->snapshot();assert(metrics.armed && !metrics.prepared && !metrics.failed && !metrics.buffer_locked && metrics.unlock_calls==1 && metrics.unlock_bytes==3200);
    // Native capture continues polling/draining while ordinary PTT is still
    // released. A 1.5s input delay must consume silence, never the phrase prefix.
    DWORD source_offset=0;
    for(unsigned step=1;step<=15;++step){
        provider->tick=6000+step*100;
        assert(SUCCEEDED(b->GetCurrentPosition(&capture,&read)));
        assert(SUCCEEDED(b->Lock(source_offset,3200,&p1,&n1,&p2,&n2,0)));
        for(DWORD i=0;i<n1;++i)assert(static_cast<unsigned char*>(p1)[i]==0);
        for(DWORD i=0;i<n2;++i)assert(static_cast<unsigned char*>(p2)[i]==0);
        assert(SUCCEEDED(b->Unlock(p1,n1,p2,n2)));
        source_offset=(source_offset+3200)%8192;
    }
    metrics=controller->snapshot();assert(metrics.armed && !metrics.source_started && !metrics.published_source_frames && !metrics.lock_nonzero_bytes);
    assert(SUCCEEDED(controller->begin_source(7500)));assert(FAILED(controller->begin_source(7500)));
    metrics=controller->snapshot();assert(metrics.source_started && metrics.source_start_tick==7500);
    provider->tick=7600;assert(SUCCEEDED(b->GetCurrentPosition(&capture,&read)));
    assert(SUCCEEDED(b->Lock(source_offset,3200,&p1,&n1,&p2,&n2,0)) && static_cast<short*>(p1)[0]==1000 && static_cast<short*>(p2)[0]==1000);
    metrics=controller->snapshot();assert(metrics.published_frames==25600 && metrics.published_source_frames==1600 && metrics.published_nonzero_frames==1600 &&
        metrics.lock_calls==17 && metrics.lock_bytes==54400 && metrics.lock_nonzero_bytes==3200 && metrics.prepared_lock_bytes==3200);
    // Cancellation cannot free or mutate an outstanding span; Unlock remains legal.
    std::thread cancelled([&]{controller->cancel();});cancelled.join();
    statistics concurrent_metrics;std::thread observer([&]{concurrent_metrics=controller->snapshot();});observer.join();
    assert(concurrent_metrics.failed && concurrent_metrics.buffer_locked && concurrent_metrics.published_frames==25600);
    assert(static_cast<short*>(p1)[0]==1000);assert(SUCCEEDED(b->Unlock(p1,n1,p2,n2)));
    metrics=controller->snapshot();assert(metrics.failed && !metrics.buffer_locked && metrics.unlock_calls==17 && metrics.unlock_bytes==54400);
    assert(FAILED(b->GetCurrentPosition(&capture,&read)) && !capture && !read);
    owned.owner.reset();provider.reset();controller.reset();dev->Release();
    assert(!weak.expired());assert(SUCCEEDED(b->Stop()));b->Release();assert(weak.expired());
    // Preparation never accepts borrowed provider lifetime or an active admission.
    provider=std::make_shared<clock_state>();owned={provider.get(),provider,now,fresh};
    environment borrowed{provider.get(),{},now,fresh};
    assert(FAILED(prepare(prep,borrowed,wave(),&dev,&controller)) && !dev && !controller);
    assert(FAILED(prepare(gate(),owned,wave(),&dev,&controller)) && !dev && !controller);
    auto too_long=prep;too_long.deadline_tick=121001;
    assert(FAILED(prepare(too_long,owned,wave(),&dev,&controller)) && !dev);
    for(int failure=0;failure<8;++failure)
    {
        provider->tick=1000;provider->protected_now=true;
        assert(SUCCEEDED(prepare(prep,owned,wave(),&dev,&controller)));
        assert(SUCCEEDED(dev->CreateCaptureBuffer(&pd,&b,nullptr)));
        assert(SUCCEEDED(b->Start(DSCBSTART_LOOPING)));
        active=gate();
        if(failure==0)active.process_id++;
        if(failure==1)active.server_port++;
        if(failure==2)provider->protected_now=false;
        if(failure==3){provider->tick=1501;active.admitted_tick=1000;}
        if(failure==4)active.deadline_tick=31001;
        if(failure==5)active.client_nonce=std::string(32,'c');
        if(failure==6)active.server_generation=std::string(32,'c');
        if(failure==7)active.slot=1;
        assert(FAILED(controller->arm(active)));
        provider->protected_now=true;active=gate();assert(FAILED(controller->arm(active)));
        assert(FAILED(b->GetCurrentPosition(&capture,&read)) && !read);
        assert(SUCCEEDED(b->Stop()));b->Release();dev->Release();controller.reset();
    }
    for(int failure=0;failure<3;++failure)
    {
        provider->tick=1000;provider->protected_now=true;
        assert(SUCCEEDED(prepare(prep,owned,wave(),&dev,&controller)));
        assert(SUCCEEDED(dev->CreateCaptureBuffer(&pd,&b,nullptr)));
        assert(SUCCEEDED(b->Start(DSCBSTART_LOOPING)));active=gate();
        assert(SUCCEEDED(controller->arm(active)));
        if(failure==0){provider->tick=1100;provider->protected_now=false;}
        if(failure==1)provider->tick=30000;
        if(failure==2)provider->tick=999;
        assert(FAILED(b->GetCurrentPosition(&capture,&read)) && !capture && !read);
        provider->tick=1100;provider->protected_now=true;
        assert(FAILED(b->GetCurrentPosition(&capture,&read)));
        assert(FAILED(controller->arm(active)));assert(SUCCEEDED(b->Stop()));
        b->Release();dev->Release();controller.reset();
    }
    for(int failure=0;failure<2;++failure){
        provider->tick=1000;provider->protected_now=true;
        assert(SUCCEEDED(prepare(prep,owned,wave(),&dev,&controller)));
        assert(SUCCEEDED(dev->CreateCaptureBuffer(&pd,&b,nullptr)));assert(SUCCEEDED(b->Start(DSCBSTART_LOOPING)));
        active=gate();assert(SUCCEEDED(controller->arm(active)));
        provider->tick=1600;
        assert(FAILED(controller->begin_source(failure==0 ? 1601 : 1000)));
        assert(controller->snapshot().failed && !controller->snapshot().source_started);
        b->Release();dev->Release();controller.reset();
    }
    // Prepared timeout and armed deadline are independent, both fail irreversibly.
    provider->tick=1000;assert(SUCCEEDED(prepare(prep,owned,wave(),&dev,&controller)));
    assert(SUCCEEDED(dev->CreateCaptureBuffer(&pd,&b,nullptr)));assert(SUCCEEDED(b->Start(DSCBSTART_LOOPING)));
    provider->tick=121000;assert(FAILED(b->GetCurrentPosition(&capture,&read)) && !read);
    b->Release();dev->Release();controller.reset();
    std::cout<<"voice_test_capture: prepared/armed/shared lifetime/concurrent locks/admission/hash/COM ABI/PCM/wrap/clock/overwrite/protection/deadline PASS\n";
}
