#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <mmreg.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <propsys.h>
#include <wrl/client.h>
#include <ks.h>
#include <ksmedia.h>
#include <bcrypt.h>
#include <array>
#include <iostream>
#include <string>
#include "RenderWave.hpp"
#pragma comment(lib,"ole32.lib")
#pragma comment(lib,"uuid.lib")
#pragma comment(lib,"bcrypt.lib")
using Microsoft::WRL::ComPtr;
void check(HRESULT hr) { if (FAILED(hr)) throw std::runtime_error("Explicit render API failed HRESULT="+std::to_string(static_cast<unsigned>(hr))); }
struct file_handle { HANDLE value;~file_handle(){if(value!=INVALID_HANDLE_VALUE)CloseHandle(value);} };
std::string digest(HANDLE file)
{
    BCRYPT_ALG_HANDLE algorithm{};BCRYPT_HASH_HANDLE hash{};
    check(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0));
    try {
        check(BCryptCreateHash(algorithm,&hash,nullptr,0,nullptr,0,0));std::array<unsigned char,4096> b{};DWORD n{};
        do {if(!ReadFile(file,b.data(),static_cast<DWORD>(b.size()),&n,nullptr))throw std::runtime_error("WAV read failed");if(n)check(BCryptHashData(hash,b.data(),n,0));}while(n);
        std::array<unsigned char,32> value{};check(BCryptFinishHash(hash,value.data(),32,0));BCryptDestroyHash(hash);hash=nullptr;BCryptCloseAlgorithmProvider(algorithm,0);algorithm=nullptr;
        const char* digits="0123456789ABCDEF";std::string result;for(auto byte:value){result+=digits[byte>>4];result+=digits[byte&15];}return result;
    } catch(...){if(hash)BCryptDestroyHash(hash);if(algorithm)BCryptCloseAlgorithmProvider(algorithm,0);throw;}
}
int wmain(int argc,wchar_t** argv)
{
    try {
        if(argc!=6 || std::wcscmp(argv[1],L"--play"))throw std::runtime_error("Usage --play exact_endpoint_id nonzero_guid expected_wav_sha256 wav_path");
        const std::wstring id=argv[2],hash=argv[4];GUID guid{},empty{};
        if(id.empty() || id.size()>512 || FAILED(CLSIDFromString(argv[3],&guid)) || IsEqualGUID(guid,empty) || hash.size()!=64 || hash.find_first_not_of(L"0123456789ABCDEFabcdef")!=std::wstring::npos)throw std::runtime_error("Invalid explicit endpoint/source identity");
        file_handle file{CreateFileW(argv[5],GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr)};
        LARGE_INTEGER size{};if(file.value==INVALID_HANDLE_VALUE || !GetFileSizeEx(file.value,&size) || size.QuadPart<44 || size.QuadPart>480102)throw std::runtime_error("Bounded source file required");
        const auto actual=digest(file.value);const std::wstring actual_hash(actual.begin(),actual.end());if(_wcsicmp(actual_hash.c_str(),hash.c_str()))throw std::runtime_error("Exact source hash changed");
        LARGE_INTEGER zero{};if(!SetFilePointerEx(file.value,zero,nullptr,FILE_BEGIN))throw std::runtime_error("Source rewind failed");
        std::vector<unsigned char> source(static_cast<std::size_t>(size.QuadPart));DWORD got{};if(!ReadFile(file.value,source.data(),static_cast<DWORD>(source.size()),&got,nullptr) || got!=source.size())throw std::runtime_error("Source read truncated");
        const auto pcm=voice_render::parse(source);
        check(CoInitializeEx(nullptr,COINIT_MULTITHREADED));struct apartment{~apartment(){CoUninitialize();}} cleanup;
        ComPtr<IMMDeviceEnumerator> enumerator;ComPtr<IMMDevice> endpoint;ComPtr<IMMEndpoint> flow;ComPtr<IPropertyStore> props;
        check(CoCreateInstance(__uuidof(MMDeviceEnumerator),nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&enumerator)));
        check(enumerator->GetDevice(id.c_str(),&endpoint));check(endpoint.As(&flow));EDataFlow direction{};check(flow->GetDataFlow(&direction));DWORD state{};check(endpoint->GetState(&state));
        if(direction!=eRender || state!=DEVICE_STATE_ACTIVE)throw std::runtime_error("Explicit render endpoint not active");
        check(endpoint->OpenPropertyStore(STGM_READ,&props));
        const PROPERTYKEY guid_key{{0x1da5d803,0xd492,0x4edd,{0x8c,0x23,0xe0,0xc0,0xff,0xee,0x7f,0x0e}},4};
        const PROPERTYKEY name_key{{0xa45c254e,0xdf1c,0x4efd,{0x80,0x20,0x67,0xd1,0x46,0xa8,0x50,0xe0}},14};
        PROPVARIANT value{};check(props->GetValue(guid_key,&value));GUID actual_guid{};const bool same=value.vt==VT_LPWSTR && value.pwszVal && SUCCEEDED(CLSIDFromString(value.pwszVal,&actual_guid)) && IsEqualGUID(guid,actual_guid);PropVariantClear(&value);
        check(props->GetValue(name_key,&value));const bool cable=value.vt==VT_LPWSTR && value.pwszVal && !std::wcscmp(value.pwszVal,L"CABLE Input (VB-Audio Virtual Cable)");PropVariantClear(&value);
        if(!same || !cable)throw std::runtime_error("Only exact approved CABLE Input allowed");
        ComPtr<IAudioClient> client;check(endpoint->Activate(__uuidof(IAudioClient),CLSCTX_INPROC_SERVER,nullptr,reinterpret_cast<void**>(client.GetAddressOf())));
        WAVEFORMATEX* raw{};check(client->GetMixFormat(&raw));struct format_owner{WAVEFORMATEX* p;~format_owner(){CoTaskMemFree(p);}} format{raw};
        bool floating=raw->wFormatTag==WAVE_FORMAT_IEEE_FLOAT,integer=raw->wFormatTag==WAVE_FORMAT_PCM;
        if(raw->wFormatTag==WAVE_FORMAT_EXTENSIBLE && raw->cbSize>=22){const auto* x=reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(raw);floating=IsEqualGUID(x->SubFormat,KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);integer=IsEqualGUID(x->SubFormat,KSDATAFORMAT_SUBTYPE_PCM);if(x->Samples.wValidBitsPerSample!=raw->wBitsPerSample)throw std::runtime_error("Unsupported valid bits");}
        if(!floating && !integer)throw std::runtime_error("Unsupported mix encoding");
        const auto total=voice_render::frames(pcm.size(),raw->nSamplesPerSec,raw->nChannels,raw->wBitsPerSample,floating);
        if(raw->nBlockAlign!=raw->nChannels*(raw->wBitsPerSample/8) || raw->nAvgBytesPerSec!=raw->nSamplesPerSec*raw->nBlockAlign)throw std::runtime_error("Invalid mix alignment");
        check(client->Initialize(AUDCLNT_SHAREMODE_SHARED,AUDCLNT_STREAMFLAGS_NOPERSIST,5000000,0,raw,nullptr));
        ComPtr<IAudioRenderClient> render;check(client->GetService(IID_PPV_ARGS(&render)));UINT capacity{};check(client->GetBufferSize(&capacity));if(!capacity || capacity>raw->nSamplesPerSec*2)throw std::runtime_error("Render buffer bound exceeded");
        struct stream_owner{IAudioClient* p;~stream_owner(){p->Stop();}} stream{client.Get()};
        std::uint64_t submitted{};bool started=false;const auto begin=GetTickCount64();
        for(;;){
            if(GetTickCount64()-begin>20000)throw std::runtime_error("Render total deadline exceeded");
            check(endpoint->GetState(&state));if(state!=DEVICE_STATE_ACTIVE)throw std::runtime_error("Endpoint protection lost");
            UINT padding{};check(client->GetCurrentPadding(&padding));if(padding>capacity)throw std::runtime_error("Invalid render padding");
            const auto n=static_cast<UINT>(std::min<std::uint64_t>(capacity-padding,total-submitted));
            if(n){BYTE* output{};check(render->GetBuffer(n,&output));voice_render::fill(output,n,submitted,pcm,raw->nSamplesPerSec,raw->nChannels,floating);check(render->ReleaseBuffer(n,0));submitted+=n;}
            if(!started){check(client->Start());started=true;}
            if(submitted==total && !n && !padding)break;Sleep(5);
        }
        check(client->Stop());std::cout<<"RENDER_COMPLETE source_frames="<<pcm.size()<<" submitted_frames="<<submitted<<" mix_rate="<<raw->nSamplesPerSec<<" channels="<<raw->nChannels<<" bits="<<raw->wBitsPerSample<<" floating="<<floating<<" default_fallback=0\n";return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
