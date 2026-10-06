// Historical tone metrics, plus opt-in exact-process synthetic-fixture WAV capture.
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
#include <bcrypt.h>
#include <tlhelp32.h>
#include "audio_recording.hpp"
#pragma comment(lib, "bcrypt.lib")
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

ComPtr<IAudioClient> activate_process(DWORD pid, std::uint64_t expected_creation, bool identity_checked = false)
{
    if (!identity_checked)
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
    }

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

struct win_handle
{
    HANDLE value{INVALID_HANDLE_VALUE};
    ~win_handle() { if (value != INVALID_HANDLE_VALUE && value) CloseHandle(value); }
    win_handle() = default;
    win_handle(const win_handle&) = delete;
    win_handle& operator=(const win_handle&) = delete;
};
std::wstring wide(const std::string& input)
{
    const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(), static_cast<int>(input.size()), nullptr, 0);
    if (!length) throw std::runtime_error("Invalid UTF8 path");
    std::wstring result(length, L'\0');
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(), static_cast<int>(input.size()), result.data(), length))
        throw std::runtime_error("Path conversion failed");
    return result;
}
std::string sha256(HANDLE file)
{
    LARGE_INTEGER zero{};
    if (!SetFilePointerEx(file, zero, nullptr, FILE_BEGIN)) throw std::runtime_error("Image seek failed");
    BCRYPT_ALG_HANDLE algorithm{}; BCRYPT_HASH_HANDLE hash{};
    auto check = [](NTSTATUS status) { if (status < 0) throw std::runtime_error("SHA256 failed"); };
    check(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0));
    try
    {
        check(BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0));
        std::array<unsigned char, 65536> buffer{}; DWORD count{};
        for (;;)
        {
            if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &count, nullptr)) throw std::runtime_error("Image read failed");
            if (!count) break;
            check(BCryptHashData(hash, buffer.data(), count, 0));
        }
        std::array<unsigned char, 32> digest{};
        check(BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0));
        BCryptDestroyHash(hash); hash = nullptr; BCryptCloseAlgorithmProvider(algorithm, 0); algorithm = nullptr;
        std::string result; const char* digits = "0123456789ABCDEF";
        for (unsigned char c : digest) { result += digits[c >> 4]; result += digits[c & 15]; }
        return result;
    }
    catch (...) { if (hash) BCryptDestroyHash(hash); if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0); throw; }
}
struct exact_process
{
    win_handle process, image;
    std::wstring expected_image;
    std::uint64_t creation;
    DWORD pid;
    explicit exact_process(const audio_recording::request& request) : expected_image(wide(request.image)), creation(request.creation), pid(request.pid)
    {
        // Require an absolute canonical path; aliases and leaf-only names are refused.
        wchar_t full[32768]{};
        const DWORD length = GetFullPathNameW(expected_image.c_str(), 32768, full, nullptr);
        if (!length || length >= 32768 || _wcsicmp(full, expected_image.c_str())) throw std::runtime_error("Expected image must be a full canonical path");
        process.value = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, request.pid);
        if (!process.value) throw std::runtime_error("Exact process access failed");
        verify();
        // Retain immutable image handle throughout capture, deny write/delete sharing.
        image.value = CreateFileW(expected_image.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (image.value == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot retain immutable expected image");
        if (_stricmp(sha256(image.value).c_str(), request.hash.c_str())) throw std::runtime_error("Expected image SHA256 mismatch");
        verify();
    }
    void verify()
    {
        if (WaitForSingleObject(process.value, 0) != WAIT_TIMEOUT) throw std::runtime_error("Exact process exited");
        FILETIME created{}, exited{}, kernel{}, user{};
        wchar_t actual_image[32768]{}; DWORD count = 32768;
        if (!GetProcessTimes(process.value, &created, &exited, &kernel, &user) ||
            !QueryFullProcessImageNameW(process.value, 0, actual_image, &count) ||
            ((static_cast<std::uint64_t>(created.dwHighDateTime) << 32) | created.dwLowDateTime) != creation ||
            _wcsicmp(actual_image, expected_image.c_str())) throw std::runtime_error("Exact PID/creation/image mismatch");
    }
    void verify_no_children()
    {
        // Windows' API includes the target tree. Refuse observed child processes
        // rather than silently presenting that scope as a single audio session.
        win_handle snapshot; snapshot.value = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot.value == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot inventory process-loopback descendants");
        PROCESSENTRY32W entry{}; entry.dwSize = sizeof(entry);
        if (!Process32FirstW(snapshot.value, &entry)) throw std::runtime_error("Cannot read process inventory");
        std::vector<std::pair<std::uint32_t, std::uint32_t>> rows;
        do {
            if (rows.size() >= 16384) throw std::runtime_error("Process inventory bound exceeded");
            rows.emplace_back(entry.th32ProcessID, entry.th32ParentProcessID);
        }
        while (Process32NextW(snapshot.value, &entry));
        if (GetLastError() != ERROR_NO_MORE_FILES) throw std::runtime_error("Incomplete process inventory");
        if (audio_recording::descendants(rows, pid)) throw std::runtime_error("Process-loopback descendant scope refused");
    }
};
void write_all(HANDLE file, const void* data, DWORD bytes)
{
    DWORD written{};
    if (!WriteFile(file, data, bytes, &written, nullptr) || written != bytes) throw std::runtime_error("WAV write failed");
}
int record_process(const audio_recording::request& request)
{
    exact_process identity(request);
    identity.verify_no_children();
    const auto path = wide(request.output);
    if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES || GetLastError() != ERROR_FILE_NOT_FOUND)
        throw std::runtime_error("Fresh output WAV in an existing directory required");
    com_apartment apartment;
    auto audio = activate_process(request.pid, request.creation, true);
    identity.verify();
    WAVEFORMATEX format{WAVE_FORMAT_PCM, 2, 48000, 192000, 4, 16, 0};
    ok(audio->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 10000000, 0, &format, nullptr));
    ComPtr<IAudioCaptureClient> capture; ok(audio->GetService(IID_PPV_ARGS(&capture)));
    win_handle output;
    output.value = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (output.value == INVALID_HANDLE_VALUE) throw std::runtime_error("Fresh exclusive output WAV required");
    // Failed captures remain identifiable by the unfinalized zero-length RIFF header.
    auto header = audio_recording::header(0); write_all(output.value, header.data(), static_cast<DWORD>(header.size()));
    std::uint32_t bytes{}; unsigned discontinuities{}, timestamp_errors{};
    const std::uint32_t limit = request.seconds * format.nAvgBytesPerSec;
    std::vector<BYTE> silence;
    bool started = false;
    try
    {
        identity.verify(); ok(audio->Start()); started = true;
        const auto begin = GetTickCount64(), end = begin + request.seconds * 1000ull;
        auto children_checked = begin;
        std::cout << "WASAPI recording ready: scope=process_tree pid=" << request.pid << " creation=" << request.creation
            << " format=pcm16 rate=48000 channels=2 tick_ms=" << begin << " fallback=0\n" << std::flush;
        while (GetTickCount64() < end)
        {
            identity.verify();
            if (GetTickCount64() - children_checked >= 100)
            {
                identity.verify_no_children(); children_checked = GetTickCount64();
            }
            UINT32 available{}; ok(capture->GetNextPacketSize(&available));
            while (available && GetTickCount64() < end)
            {
                identity.verify();
                BYTE* data{}; UINT32 count{}; DWORD flags{};
                ok(capture->GetBuffer(&data, &count, &flags, nullptr, nullptr));
                try
                {
                    if (count > (limit - bytes) / format.nBlockAlign) throw std::runtime_error("WAV duration/size bound exceeded");
                    const DWORD size = count * format.nBlockAlign;
                    if (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) ++discontinuities;
                    if (flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) ++timestamp_errors;
                    if (flags & AUDCLNT_BUFFERFLAGS_SILENT) { silence.assign(size, 0); data = silence.data(); }
                    if (size && !data) throw std::runtime_error("Missing audio payload");
                    write_all(output.value, data, size); bytes += size;
                }
                catch (...) { capture->ReleaseBuffer(count); throw; }
                ok(capture->ReleaseBuffer(count)); ok(capture->GetNextPacketSize(&available));
            }
            Sleep(5);
        }
        identity.verify(); identity.verify_no_children(); ok(audio->Stop()); started = false;
        if (!bytes) throw std::runtime_error("No process audio frames captured");
        LARGE_INTEGER zero{};
        if (!SetFilePointerEx(output.value, zero, nullptr, FILE_BEGIN)) throw std::runtime_error("WAV finalization seek failed");
        header = audio_recording::header(bytes); write_all(output.value, header.data(), static_cast<DWORD>(header.size()));
        if (!FlushFileBuffers(output.value)) throw std::runtime_error("WAV flush failed");
        std::cout << "WASAPI recording complete: bytes=" << bytes << " frames=" << bytes / 4 << " elapsed_ms=" << GetTickCount64() - begin
            << " discontinuities=" << discontinuities << " timestamp_errors=" << timestamp_errors
            << " source=process_tree synthetic_fixture_only=1 human_acceptance=0\n";
        return 0;
    }
    catch (...) { if (started) audio->Stop(); throw; }
}
void recording_self_test()
{
    if (audio_recording::descendants({{10,1},{20,10},{30,20},{40,1}},10) != 2 ||
        audio_recording::descendants({{10,1},{30,20}},10) != 0) throw std::runtime_error("Process-tree closure regression");
    for (const auto& rows : {std::vector<std::pair<std::uint32_t,std::uint32_t>>{{10,20},{20,10}},
        std::vector<std::pair<std::uint32_t,std::uint32_t>>{{10,1},{20,10},{20,10}}})
    {
        bool rejected = false; try { audio_recording::descendants(rows,10); } catch (...) { rejected = true; }
        if (!rejected) throw std::runtime_error("Cyclic/ambiguous process inventory accepted");
    }
    const auto header = audio_recording::header(192000);
    auto u32 = [&](unsigned offset) {
        return static_cast<std::uint32_t>(header[offset]) | (static_cast<std::uint32_t>(header[offset + 1]) << 8) |
            (static_cast<std::uint32_t>(header[offset + 2]) << 16) | (static_cast<std::uint32_t>(header[offset + 3]) << 24);
    };
    if (u32(4) != 192036 || u32(40) != 192000 || u32(24) != 48000 || header[20] != 1 || header[22] != 2 || header[34] != 16)
        throw std::runtime_error("PCM WAV header regression");
    for (const std::uint32_t bytes : {1u, 60u * 192000 + 4})
    {
        bool rejected = false; try { audio_recording::header(bytes); } catch (...) { rejected = true; }
        if (!rejected) throw std::runtime_error("WAV bound regression");
    }
    std::array<std::string, 8> values{"probe", "--record", "5", "1", "123", "C:\\test.exe", std::string(64, 'A'), "out.wav"};
    auto parse = [&]() {
        std::array<char*, 8> args{};
        for (unsigned i = 0; i < args.size(); ++i) args[i] = values[i].data();
        return audio_recording::parse(static_cast<int>(args.size()), args.data());
    };
    if (parse().seconds != 5) throw std::runtime_error("Record argument regression");
    auto refuse = [&](unsigned index, const std::string& invalid) {
        const auto prior = values[index]; values[index] = invalid;
        bool rejected = false; try { parse(); } catch (...) { rejected = true; } values[index] = prior;
        if (!rejected) throw std::runtime_error("Invalid record argument accepted");
    };
    for (const std::string invalid : {"0", "61", "-1", "1junk", "18446744073709551616"}) refuse(2, invalid);
    refuse(3, "4294967296"); refuse(4, "0"); refuse(6, std::string(64, 'Z')); refuse(7, "");
    wchar_t image_path[32768]{}; DWORD length = 32768;
    FILETIME creation{}, exit{}, kernel{}, user{};
    if (!QueryFullProcessImageNameW(GetCurrentProcess(), 0, image_path, &length) || !GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user))
        throw std::runtime_error("Self identity unavailable");
    const int utf8_length = WideCharToMultiByte(CP_UTF8, 0, image_path, static_cast<int>(length), nullptr, 0, nullptr, nullptr);
    std::string image_utf8(utf8_length, '\0');
    WideCharToMultiByte(CP_UTF8, 0, image_path, static_cast<int>(length), image_utf8.data(), utf8_length, nullptr, nullptr);
    win_handle file; file.value = CreateFileW(image_path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file.value == INVALID_HANDLE_VALUE) throw std::runtime_error("Self image unavailable");
    audio_recording::request request{1, GetCurrentProcessId(), (static_cast<std::uint64_t>(creation.dwHighDateTime) << 32) | creation.dwLowDateTime, image_utf8, sha256(file.value), "unused.wav"};
    exact_process valid(request); valid.verify();
    auto refuse_identity = [&](const audio_recording::request& invalid) {
        bool rejected = false; try { exact_process wrong(invalid); } catch (...) { rejected = true; }
        if (!rejected) throw std::runtime_error("Foreign identity accepted");
    };
    auto wrong = request; ++wrong.creation; refuse_identity(wrong);
    wrong = request; wrong.pid = UINT32_MAX; refuse_identity(wrong);
    wrong = request; wrong.hash = std::string(64, '0'); refuse_identity(wrong);
    wrong = request; wrong.image = "audio-output-probe.exe"; refuse_identity(wrong);
    wrong = request; wrong.image += ".foreign"; refuse_identity(wrong);
    std::cout << "PASS: strict recording arguments, real immutable self-image SHA256/PID/creation and foreign identity rejection, PCM header/frame/size bounds; no capture activated.\n";
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
int probe_main(int argc, char** argv)
{
    try
    {
        if (argc > 1 && std::string(argv[1]) == "--record") return record_process(audio_recording::parse(argc, argv));
        if (argc == 2 && std::string(argv[1]) == "--self-test")
        {
            recording_self_test();
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
int wmain(int argc, wchar_t** argv)
{
    std::vector<std::string> values(static_cast<std::size_t>(argc));
    std::vector<char*> pointers(static_cast<std::size_t>(argc));
    for (int i = 0; i < argc; ++i)
    {
        const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, argv[i], -1, nullptr, 0, nullptr, nullptr);
        if (!length) return 2;
        values[i].resize(static_cast<std::size_t>(length));
        if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, argv[i], -1, values[i].data(), length, nullptr, nullptr)) return 2;
        pointers[i] = values[i].data();
    }
    return probe_main(argc, pointers.data());
}
