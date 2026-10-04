// Technical output measurement only: no audio samples are saved or transmitted.
#define NOMINMAX
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <ksmedia.h>
#include <wrl/client.h>
#include <wrl/implements.h>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <algorithm>
#include <array>
#include <complex>
#include <vector>
#include <memory>
using Microsoft::WRL::ComPtr;
void ok(HRESULT value) { if (FAILED(value)) throw std::runtime_error("WASAPI HRESULT " + std::to_string(static_cast<unsigned long>(value))); }
struct com_apartment
{
    com_apartment() { ok(CoInitializeEx(nullptr, COINIT_MULTITHREADED)); }
    ~com_apartment() { CoUninitialize(); }
};

class process_activation final : public Microsoft::WRL::RuntimeClass<
    Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
    Microsoft::WRL::FtmBase, IActivateAudioInterfaceCompletionHandler>
{
public:
    process_activation() : done(CreateEventW(nullptr, TRUE, FALSE, nullptr))
    {
        if (!done) throw std::runtime_error("Process loopback event creation failed");
    }
    ~process_activation() { CloseHandle(done); }
    STDMETHOD(ActivateCompleted)(IActivateAudioInterfaceAsyncOperation* operation) override
    {
        HRESULT activation_result{};
        ComPtr<IUnknown> activated;
        HRESULT result = operation->GetActivateResult(&activation_result, &activated);
        if (SUCCEEDED(result)) result = activation_result;
        if (SUCCEEDED(result)) result = activated.As(&audio);
        status.store(result, std::memory_order_release);
        SetEvent(done);
        return S_OK;
    }
    HANDLE done;
    std::atomic<HRESULT> status{E_PENDING};
    ComPtr<IAudioClient> audio;
};

ComPtr<IAudioClient> activate_process(DWORD pid, std::uint64_t expected_creation)
{
    const HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) throw std::runtime_error("Owned observation process access failed");
    FILETIME created{}, exited{}, kernel{}, user{};
    wchar_t image[32768]{}; DWORD image_size = 32768;
    const bool readable = GetProcessTimes(process, &created, &exited, &kernel, &user) &&
        QueryFullProcessImageNameW(process, 0, image, &image_size);
    CloseHandle(process);
    const auto actual = (static_cast<std::uint64_t>(created.dwHighDateTime) << 32) | created.dwLowDateTime;
    const auto delta = actual > expected_creation ? actual - expected_creation : expected_creation - actual;
    const auto* leaf = wcsrchr(image, L'\\');
    if (!readable || delta > 10 || !leaf || _wcsicmp(leaf + 1, L"iw7-paris-native-trace.exe"))
        throw std::runtime_error("Owned observation process identity mismatch");

    AUDIOCLIENT_ACTIVATION_PARAMS parameters{};
    parameters.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    parameters.ProcessLoopbackParams.TargetProcessId = pid;
    parameters.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
    PROPVARIANT activation{};
    activation.vt = VT_BLOB;
    activation.blob.cbSize = sizeof(parameters);
    activation.blob.pBlobData = reinterpret_cast<BYTE*>(&parameters);
    auto completion = Microsoft::WRL::Make<process_activation>();
    ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
    ok(ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient),
        &activation, completion.Get(), &operation));
    if (WaitForSingleObject(completion->done, 10000) != WAIT_OBJECT_0)
        throw std::runtime_error("Process loopback activation exceeded ten seconds");
    ok(completion->status.load(std::memory_order_acquire));
    return completion->audio;
}
// Broad spectral diagnostics explain a failed target detector without changing
// its acceptance threshold. Samples stay in memory and are never recorded.
double spectral_frequency(const std::vector<double>& samples, unsigned rate)
{
    std::size_t size = 1;
    while (size < samples.size()) size *= 2;
    std::vector<std::complex<double>> spectrum(size);
    for (std::size_t i = 0; i < samples.size(); ++i) spectrum[i] = samples[i];
    for (std::size_t i = 1, j = 0; i < size; ++i)
    {
        std::size_t bit = size >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(spectrum[i], spectrum[j]);
    }
    for (std::size_t width = 2; width <= size; width *= 2)
    {
        const auto step = std::polar(1.0, -6.283185307179586 / width);
        for (std::size_t start = 0; start < size; start += width)
        {
            std::complex<double> phase(1.0);
            for (std::size_t i = 0; i < width / 2; ++i)
            {
                const auto even = spectrum[start + i], odd = phase * spectrum[start + i + width / 2];
                spectrum[start + i] = even + odd; spectrum[start + i + width / 2] = even - odd;
                phase *= step;
            }
        }
    }
    std::size_t peak = (100 * size + rate - 1) / rate;
    for (std::size_t i = peak; i < size / 2 && i * rate / size <= 10000; ++i)
        if (std::norm(spectrum[i]) > std::norm(spectrum[peak])) peak = i;
    return static_cast<double>(peak) * rate / size;
}
int main(int argc, char** argv)
{
    try
    {
        if (argc == 2 && std::string(argv[1]) == "--self-test")
        {
            for (unsigned frequency : {440u, 997u, 1600u})
            {
                std::vector<double> samples(4800);
                for (unsigned i = 0; i < samples.size(); ++i) samples[i] = std::sin(6.283185307179586 * frequency * i / 48000);
                if (std::abs(spectral_frequency(samples, 48000) - frequency) > 6) return 2;
            }
            std::cout << "PASS: broad spectral diagnostic locates three known signals within one FFT bin.\n";
            return 0;
        }
        const unsigned seconds = argc > 1 ? static_cast<unsigned>(std::stoul(argv[1])) : 45;
        if (seconds > 600 || seconds == 0) return 2;
        const unsigned target_hz = argc > 2 ? static_cast<unsigned>(std::stoul(argv[2])) : 440;
        if (target_hz < 100 || target_hz > 10000) return 2;
        com_apartment apartment;
        const bool per_process = argc == 5;
        if (argc != 1 && argc != 2 && argc != 3 && !per_process) return 2;
        ComPtr<IAudioClient> audio;
        WAVEFORMATEX* format{};
        std::unique_ptr<WAVEFORMATEX, decltype(&CoTaskMemFree)> owned_format(nullptr, CoTaskMemFree);
        WAVEFORMATEX process_format{};
        if (per_process)
        {
            audio = activate_process(static_cast<DWORD>(std::stoul(argv[3])), std::stoull(argv[4]));
            // A virtual process endpoint has no device mix format. This passive
            // filter changes no mute, volume, device or game setting.
            process_format = {WAVE_FORMAT_PCM, 2, 48000, 192000, 4, 16, 0};
            format = &process_format;
        }
        else
        {
            ComPtr<IMMDeviceEnumerator> enumerator;
            ok(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator)));
            ComPtr<IMMDevice> device; ok(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device));
            ok(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(audio.GetAddressOf())));
            ok(audio->GetMixFormat(&format));
            owned_format.reset(format);
        }
        bool floating = format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
        if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE)
            floating = IsEqualGUID(reinterpret_cast<WAVEFORMATEXTENSIBLE*>(format)->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
        if (!per_process && (!floating || format->wBitsPerSample != 32)) throw std::runtime_error("Probe supports native float32 mix format only");
        const unsigned channels = format->nChannels, rate = format->nSamplesPerSec;
        ok(audio->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 10000000, 0, format, nullptr));
        ComPtr<IAudioCaptureClient> capture; ok(audio->GetService(IID_PPV_ARGS(&capture)));
        ok(audio->Start());
        std::cout << "WASAPI observation ready: scope=" << (per_process ? "process" : "device") << "." << std::endl;
        const auto end = GetTickCount64() + seconds * 1000ull;
        double peak_rms{}, peak_tone_ratio{}, peak_frequency{}; std::uint64_t frames{}, strong_windows{};
        std::array<double, 17> re{}, im{};
        double power{}; unsigned window_count{};
        const unsigned window_size = rate / 10; // 100 ms matched-frequency windows
        std::vector<double> window; window.reserve(window_size);
        while (GetTickCount64() < end)
        {
            UINT32 available{}; ok(capture->GetNextPacketSize(&available));
            while (available)
            {
                BYTE* data{}; UINT32 count{}; DWORD flags{};
                ok(capture->GetBuffer(&data, &count, &flags, nullptr, nullptr));
                for (unsigned i = 0; i < count; ++i)
                {
                    double sample{};
                    if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT))
                        for (unsigned c = 0; c < channels; ++c)
                            sample += (floating ? reinterpret_cast<const float*>(data)[i * channels + c] :
                                reinterpret_cast<const short*>(data)[i * channels + c] / 32768.0) / channels;
                    // Native DirectSound adjusts playback frequency around the nominal
                    // rate to control its queue. Cover target +/-40 Hz in 5 Hz steps.
                    for (unsigned bin = 0; bin < re.size(); ++bin)
                    {
                        const double phase = 6.283185307179586 * (target_hz - 40 + 5 * bin) * window_count / rate;
                        re[bin] += sample * std::cos(phase); im[bin] += sample * std::sin(phase);
                    }
                    power += sample * sample;
                    window.push_back(sample);
                    ++frames; ++window_count;
                    if (window_count == window_size)
                    {
                        const double rms = std::sqrt(power / window_count);
                        double ratio{};
                        for (unsigned bin = 0; bin < re.size(); ++bin)
                        {
                            const double value = power > 0 ? 2 * (re[bin] * re[bin] + im[bin] * im[bin]) / (window_count * power) : 0;
                            ratio = std::max(ratio, value);
                            if (value > peak_tone_ratio) { peak_tone_ratio = value; peak_frequency = target_hz - 40 + 5 * bin; }
                        }
                        peak_rms = std::max(peak_rms, rms);
                        if (rms > 0.01 && ratio > 0.4)
                        {
                            ++strong_windows;
                            std::cout << "Target window: tick_ms=" << GetTickCount64()
                                << " rms=" << rms << " target_ratio=" << ratio << "\n";
                        }
                        if (rms > 0.05) std::cout << "Active window: tick_ms=" << GetTickCount64()
                            << " rms=" << rms << " target_ratio=" << ratio
                            << " spectral_frequency=" << spectral_frequency(window, rate) << "\n";
                        window.clear();
                        re.fill(0); im.fill(0); power = 0; window_count = 0;
                    }
                }
                ok(capture->ReleaseBuffer(count)); ok(capture->GetNextPacketSize(&available));
            }
            Sleep(5);
        }
        ok(audio->Stop());
        std::cout << "WASAPI loopback: frames=" << frames << " rate=" << rate << " channels=" << channels
                  << " peak_rms=" << peak_rms << " peak_tone_ratio=" << peak_tone_ratio << " peak_frequency=" << peak_frequency << " strong_tone_windows=" << strong_windows
                  << " (metrics only, no recordings saved).\n";
        return strong_windows ? 0 : 1;
    }
    catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 2; }
}
