#include "CaptureAdapterPolicy.hpp"
#include <iostream>
#include <stdexcept>
using namespace iw7_voice_capture_plan;
unsigned calls{}; const GUID* selected{}; LPDIRECTSOUNDCAPTURE* selected_output{};
HRESULT WINAPI fake(LPCGUID guid, LPDIRECTSOUNDCAPTURE* output, LPUNKNOWN)
{
    ++calls; selected = guid; selected_output = output; return S_FALSE;
}
void require(bool value) { if (!value) throw std::runtime_error("capture adapter policy regression"); }
struct fake_enumerator final : IMMDeviceEnumerator
{
    unsigned defaults{},explicit_calls{};HRESULT result=S_FALSE;std::wstring last_id;
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID,void**) override { return E_NOINTERFACE; }
    ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
    ULONG STDMETHODCALLTYPE Release() override { return 1; }
    HRESULT STDMETHODCALLTYPE EnumAudioEndpoints(EDataFlow,DWORD,IMMDeviceCollection**) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetDefaultAudioEndpoint(EDataFlow,ERole,IMMDevice**) override { ++defaults;return result; }
    HRESULT STDMETHODCALLTYPE GetDevice(LPCWSTR id,IMMDevice**) override { ++explicit_calls;last_id=id;return result; }
    HRESULT STDMETHODCALLTYPE RegisterEndpointNotificationCallback(IMMNotificationClient*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE UnregisterEndpointNotificationCallback(IMMNotificationClient*) override { return E_NOTIMPL; }
};
int main()
{
    try
    {
        LPDIRECTSOUNDCAPTURE output{}, foreign{};
        require(selector_intent(false,false,false) == intent::ordinary);
        require(selector_intent(true,false,false) == intent::invalid);
        require(selector_intent(false,false,true) == intent::invalid);
        require(selector_intent(true,true,true) == intent::explicit_route);
        require(guard_hresult([]() -> HRESULT { throw std::bad_alloc(); },DSERR_INVALIDPARAM) == DSERR_INVALIDPARAM);
        require(guard_hresult([]() -> HRESULT { throw std::runtime_error("IO"); },E_INVALIDARG) == E_INVALIDARG);
        context valid{};
        valid.requested = valid.isolated_build = valid.client_test_flag = valid.isolated_flag = valid.marker_verified =
            valid.owned_identity = valid.signatures_verified = valid.endpoint_active = valid.endpoint_capture = valid.endpoint_virtual = true;
        valid.server_port = 27116; valid.core_matches = valid.directsound_matches = 1;
        valid.endpoint_guid.Data1 = 0x12345678; valid.expected_output = &output;
        require(dispatch(valid, fake, nullptr, &output, nullptr) == S_FALSE && calls == 1 && selected == &valid.endpoint_guid && selected_output == &output);
        auto reject = [&](context wrong) { const auto before = calls; require(dispatch(wrong, fake, nullptr, &output, nullptr) == DSERR_INVALIDPARAM && calls == before); };
        auto wrong = valid; wrong.isolated_build = false; reject(wrong);
        wrong = valid; wrong.client_test_flag = false; reject(wrong);
        wrong = valid; wrong.isolated_flag = false; reject(wrong);
        wrong = valid; wrong.marker_verified = false; reject(wrong);
        wrong = valid; wrong.owned_identity = false; reject(wrong);
        wrong = valid; wrong.signatures_verified = false; reject(wrong);
        wrong = valid; wrong.server_port = 27016; reject(wrong);
        wrong = valid; wrong.core_matches = 2; reject(wrong);
        wrong = valid; wrong.directsound_matches = 0; reject(wrong);
        wrong = valid; wrong.endpoint_active = false; reject(wrong);
        wrong = valid; wrong.endpoint_virtual = false; reject(wrong);
        wrong = valid; wrong.endpoint_capture = false; reject(wrong);
        wrong = valid; wrong.directsound_default_alias = true; reject(wrong);
        wrong = valid; wrong.endpoint_guid = {}; reject(wrong);
        const auto before = calls;
        require(dispatch(valid, fake, &valid.endpoint_guid, &output, nullptr) == DSERR_INVALIDPARAM);
        require(dispatch(valid, fake, nullptr, &foreign, nullptr) == DSERR_INVALIDPARAM);
        require(calls == before);
        wrong = valid; wrong.requested = false;
        require(dispatch(wrong, fake, nullptr, &output, nullptr) == S_FALSE && selected == nullptr);
        require(dispatch(valid, nullptr, nullptr, &output, nullptr) == DSERR_NODRIVER);
        fake_enumerator volume;IMMDevice* device{};
        require(volume_endpoint(valid,&volume,eCapture,eConsole,&device,L"approved-exact-id") == S_FALSE && volume.explicit_calls == 1 && !volume.defaults && volume.last_id == L"approved-exact-id");
        volume.result=E_FAIL;
        require(volume_endpoint(valid,&volume,eCapture,eConsole,&device,L"approved-exact-id") == E_FAIL && !volume.defaults);
        require(volume_endpoint(valid,&volume,eRender,eConsole,&device,L"approved-exact-id") == E_INVALIDARG && volume.explicit_calls == 2);
        wrong=valid;wrong.owned_identity=false;
        require(volume_endpoint(wrong,&volume,eCapture,eConsole,&device,L"approved-exact-id") == E_INVALIDARG && !volume.defaults);
        wrong.requested=false;
        require(volume_endpoint(wrong,&volume,eCapture,eConsole,&device,L"unused") == E_FAIL && volume.defaults == 1);
        require(cable_output(L"CABLE Output (VB-Audio Virtual Cable)") && !cable_output(L"Owner Microphone") && !cable_output(L"CABLE Output other"));
        std::cout << "PASS capture factory preparatory policy: explicit GUID only when all lab/identity/signature/endpoint guards pass; normal call preserved and HRESULT unchanged; no audio API executed.\n";
        return 0;
    }
    catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
