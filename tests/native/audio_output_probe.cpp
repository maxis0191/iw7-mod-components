// Technical output measurement only: no audio samples are saved or transmitted.
#define NOMINMAX
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <ksmedia.h>
#include <wrl/client.h>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <algorithm>
#include <array>
using Microsoft::WRL::ComPtr;
void ok(HRESULT value) { if (FAILED(value)) throw std::runtime_error("WASAPI HRESULT " + std::to_string(static_cast<unsigned long>(value))); }
int main(int argc, char** argv)
{
    try
    {
        const unsigned seconds = argc > 1 ? static_cast<unsigned>(std::stoul(argv[1])) : 45;
        if (seconds > 120 || seconds == 0) return 2;
        const unsigned target_hz = argc > 2 ? static_cast<unsigned>(std::stoul(argv[2])) : 440;
        if (target_hz < 100 || target_hz > 10000) return 2;
        ok(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
        ComPtr<IMMDeviceEnumerator> enumerator;
        ok(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator)));
        ComPtr<IMMDevice> device; ok(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device));
        ComPtr<IAudioClient> audio; ok(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(audio.GetAddressOf())));
        WAVEFORMATEX* format{}; ok(audio->GetMixFormat(&format));
        bool floating = format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
        if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE)
            floating = IsEqualGUID(reinterpret_cast<WAVEFORMATEXTENSIBLE*>(format)->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
        if (!floating || format->wBitsPerSample != 32) { CoTaskMemFree(format); throw std::runtime_error("Probe supports native float32 mix format only"); }
        const unsigned channels = format->nChannels, rate = format->nSamplesPerSec;
        ok(audio->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 10000000, 0, format, nullptr));
        CoTaskMemFree(format);
        ComPtr<IAudioCaptureClient> capture; ok(audio->GetService(IID_PPV_ARGS(&capture)));
        ok(audio->Start());
        const auto end = GetTickCount64() + seconds * 1000ull;
        double peak_rms{}, peak_tone_ratio{}, peak_frequency{}; std::uint64_t frames{}, strong_windows{};
        std::array<double, 17> re{}, im{};
        double power{}; unsigned window_count{};
        const unsigned window_size = rate / 10; // 100 ms matched-frequency windows
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
                        for (unsigned c = 0; c < channels; ++c) sample += reinterpret_cast<const float*>(data)[i * channels + c] / channels;
                    // Native DirectSound adjusts playback frequency around the nominal
                    // rate to control its queue. Cover target +/-40 Hz in 5 Hz steps.
                    for (unsigned bin = 0; bin < re.size(); ++bin)
                    {
                        const double phase = 6.283185307179586 * (target_hz - 40 + 5 * bin) * window_count / rate;
                        re[bin] += sample * std::cos(phase); im[bin] += sample * std::sin(phase);
                    }
                    power += sample * sample;
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
                        if (rms > 0.01 && ratio > 0.4) ++strong_windows;
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
        CoUninitialize();
        return strong_windows ? 0 : 1;
    }
    catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 2; }
}
