#pragma once
// Shared native/test policy. The component is included only in isolated builds.
#include <windows.h>
#include <mmreg.h>
#include <dsound.h>
#include <cstring>
#include <mmdeviceapi.h>
#include <propsys.h>
#include <wrl/client.h>
#include <string>
#include <cwchar>
#pragma comment(lib, "dsound.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "uuid.lib")

namespace iw7_voice_capture_plan
{
enum class intent { ordinary, explicit_route, invalid };
inline intent selector_intent(bool guid_present,bool guid_nonempty,bool secondary_present)
{
    if (!guid_present) return secondary_present ? intent::invalid : intent::ordinary;
    return guid_nonempty ? intent::explicit_route : intent::invalid;
}
template <typename Function> inline HRESULT guard_hresult(Function&& function,HRESULT failure) noexcept
{
    try { return function(); } catch (...) { return failure; }
}
using factory = HRESULT (WINAPI*)(LPCGUID, LPDIRECTSOUNDCAPTURE*, LPUNKNOWN);
struct context
{
    bool requested{}, isolated_build{}, client_test_flag{}, isolated_flag{}, marker_verified{}, owned_identity{}, signatures_verified{};
    unsigned server_port{};
    unsigned core_matches{}, directsound_matches{};
    bool endpoint_active{}, endpoint_capture{}, endpoint_virtual{}, directsound_default_alias{};
    GUID endpoint_guid{};
    LPDIRECTSOUNDCAPTURE* expected_output{};
};
inline bool permitted(const context& value)
{
    const GUID empty{};
    return value.requested && value.isolated_build && value.client_test_flag && value.isolated_flag && value.marker_verified &&
        value.owned_identity && value.signatures_verified && value.server_port >= 27100 && value.server_port <= 27999 &&
        value.core_matches == 1 && value.directsound_matches == 1 && value.endpoint_active && value.endpoint_capture &&
        value.endpoint_virtual && !value.directsound_default_alias && value.expected_output &&
        std::memcmp(&value.endpoint_guid, &empty, sizeof(GUID)) != 0;
}
inline HRESULT dispatch(const context& value, factory original, LPCGUID original_guid, LPDIRECTSOUNDCAPTURE* output, LPUNKNOWN outer)
{
    if (!original) return DSERR_NODRIVER;
    if (!value.requested) return original(original_guid, output, outer);
    // Expected retail factory passes NULL GUID/aggregation. Refuse unexpected
    // callers and lost validation; never fall back to the personal default mic.
    if (!permitted(value) || original_guid || outer || output != value.expected_output) return DSERR_INVALIDPARAM;
    return original(&value.endpoint_guid, output, outer);
}
inline bool cable_output(const wchar_t* name)
{
    return name && std::wcscmp(name,L"CABLE Output (VB-Audio Virtual Cable)") == 0;
}
// Enumeration/property reads only. No stream, default setter or gain access.
inline bool correlate_endpoint(context& c, const std::wstring& approved_id)
{
    c.core_matches=c.directsound_matches=0;
    c.endpoint_active=c.endpoint_capture=c.endpoint_virtual=false;
    const auto init=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    if (FAILED(init) && init != RPC_E_CHANGED_MODE) return false;
    struct apartment { bool owned; ~apartment() { if (owned) CoUninitialize(); } } cleanup{SUCCEEDED(init)};
    Microsoft::WRL::ComPtr<IMMDeviceEnumerator> enumerator;
    Microsoft::WRL::ComPtr<IMMDeviceCollection> devices;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator),nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&enumerator))) ||
        FAILED(enumerator->EnumAudioEndpoints(eCapture,DEVICE_STATEMASK_ALL,&devices))) return false;
    UINT count{};if (FAILED(devices->GetCount(&count)) || count > 1024) return false;
    const PROPERTYKEY guid_key{{0x1da5d803,0xd492,0x4edd,{0x8c,0x23,0xe0,0xc0,0xff,0xee,0x7f,0x0e}},4};
    const PROPERTYKEY name_key{{0xa45c254e,0xdf1c,0x4efd,{0x80,0x20,0x67,0xd1,0x46,0xa8,0x50,0xe0}},14};
    for (UINT i=0;i<count;++i)
    {
        Microsoft::WRL::ComPtr<IMMDevice> device;Microsoft::WRL::ComPtr<IPropertyStore> properties;
        if (FAILED(devices->Item(i,&device)) || FAILED(device->OpenPropertyStore(STGM_READ,&properties))) return false;
        PROPVARIANT value{};if (FAILED(properties->GetValue(guid_key,&value))) return false;
        GUID guid{};const bool same=value.vt == VT_LPWSTR && value.pwszVal && SUCCEEDED(CLSIDFromString(value.pwszVal,&guid)) && IsEqualGUID(guid,c.endpoint_guid);
        PropVariantClear(&value);if (!same) continue;
        ++c.core_matches;
        LPWSTR id{};DWORD state{};if (FAILED(device->GetId(&id))) return false;
        const bool exact=id && approved_id == id;CoTaskMemFree(id);
        if (FAILED(device->GetState(&state)) || FAILED(properties->GetValue(name_key,&value))) return false;
        const bool virtual_name=value.vt == VT_LPWSTR && cable_output(value.pwszVal);PropVariantClear(&value);
        c.endpoint_active=state == DEVICE_STATE_ACTIVE;c.endpoint_capture=exact;c.endpoint_virtual=virtual_name;
    }
    struct enumeration { context* c;unsigned seen{};bool failed{}; } state{&c};
    const auto callback=[](LPGUID guid,LPCWSTR name,LPCWSTR,LPVOID opaque)->BOOL
    {
        auto& s=*static_cast<enumeration*>(opaque);
        if (++s.seen > 1024) { s.failed=true;return FALSE; }
        if (guid && IsEqualGUID(*guid,s.c->endpoint_guid)) { ++s.c->directsound_matches;if (!cable_output(name)) s.failed=true; }
        return TRUE;
    };
    return SUCCEEDED(DirectSoundCaptureEnumerateW(callback,&state)) && !state.failed && permitted(c);
}
inline HRESULT volume_endpoint(const context& c,IMMDeviceEnumerator* enumerator,EDataFlow flow,ERole role,
    IMMDevice** output,const std::wstring& approved_id)
{
    if (!enumerator || !output) return E_POINTER;
    if (!c.requested) return enumerator->GetDefaultAudioEndpoint(flow,role,output);
    if (!permitted(c) || flow != eCapture || role != eConsole || approved_id.empty()) return E_INVALIDARG;
    *output=nullptr;
    return enumerator->GetDevice(approved_id.c_str(),output);
}
}
