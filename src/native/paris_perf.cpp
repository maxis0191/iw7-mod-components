#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "scheduler.hpp"
#include "command.hpp"
#include "console/console.hpp"
#include "paris_stack.hpp"
#include <utils/flags.hpp>
#include <utils/io.hpp>
#include <tlhelp32.h>
#include <psapi.h>

// Performance recorder for isolated lab clients (-paris-perf with -paris-isolated-lab).
//
//   paris_perf_begin <name>   start a measurement window
//   paris_perf_end            stop it and write iw7-mod/paris-perf/<name>.json
//
// A window holds every frame interval (one timestamp per pass of the renderer pipeline), a sampling profile of the
// game's threads (program counter plus the call stack inside the game image, about 1000 samples a second for the main
// and render threads and a rotating share for the others), the CPU time of every thread, the module list and the
// process memory. Nothing is measured outside a window except the frame clock. Addresses are raw: the engine map
// (ops/engine-map) turns them into functions offline.
//
// Sampler rule: between SuspendThread and ResumeThread it touches no heap, no file and no lock. A suspended thread
// may hold any of them. Function entries of the game image come from its own exception directory, read once.
namespace paris_perf
{
    namespace
    {
        // The stack capture (image reading, unwind, raw_sample) is shared with the hang reporter: paris_stack.hpp.
        using paris_stack::capture;
        using paris_stack::function_count;
        using paris_stack::image_base;
        using paris_stack::raw_sample;
        using paris_stack::read_image;
        using paris_stack::text_begin;
        using paris_stack::text_end;
        using paris_stack::unwind_ready;

        constexpr std::size_t max_frames = 1u << 20;
        constexpr std::size_t max_threads = 200;
        constexpr std::size_t others_per_tick = 3;
        constexpr std::size_t max_stacks = 200000;

        struct thread_info
        {
            DWORD id{};
            HANDLE handle{};
            int role{}; // 0 main, 1 render, 2 other
            ULONGLONG user0{}, kernel0{}, user1{}, kernel1{};
            std::uint64_t samples{};
            std::uint64_t failures{};
        };

        std::atomic<DWORD> main_thread{0}, render_thread{0};
        std::vector<std::int64_t> frame_qpc;       // renderer thread writes while a window is open
        std::atomic<bool> window_open{false};
        std::atomic<bool> sampler_stop{false};
        std::thread sampler;
        std::mutex window_mutex;                   // begin/end only
        std::string window_name;
        std::int64_t qpc_hz{}, begin_qpc{}, end_qpc{};
        std::vector<thread_info> threads;
        std::map<std::string, std::uint32_t> stacks; // key: thread index byte, depth byte, scan byte, then the addresses
        std::uint64_t ticks{}, dropped{};

        std::int64_t now()
        {
            LARGE_INTEGER value{};
            QueryPerformanceCounter(&value);
            return value.QuadPart;
        }
        void account(const std::size_t index, const raw_sample& sample)
        {
            std::string key;
            key.reserve(3 + (sample.depth + sample.scanned) * 8);
            key.push_back(static_cast<char>(index));
            key.push_back(static_cast<char>(sample.depth));
            key.push_back(static_cast<char>(sample.scanned));
            key.append(reinterpret_cast<const char*>(sample.pc), sample.depth * sizeof(std::uint64_t));
            key.append(reinterpret_cast<const char*>(sample.scan), sample.scanned * sizeof(std::uint64_t));
            const auto found = stacks.find(key);
            if (found != stacks.end()) ++found->second;
            else if (stacks.size() < max_stacks) stacks.emplace(std::move(key), 1u);
            else ++dropped;
        }
        void sample_thread(const std::size_t index)
        {
            auto& thread = threads[index];
            raw_sample sample{};
            if (SuspendThread(thread.handle) == static_cast<DWORD>(-1)) { ++thread.failures; return; }
            const bool ok = capture(thread.handle, sample);
            ResumeThread(thread.handle);
            if (!ok) { ++thread.failures; return; }
            ++thread.samples;
            account(index, sample);
        }
        void sampler_loop()
        {
            // A high-resolution waitable timer: about one tick a millisecond without touching the system timer period.
            const HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, 0x00000002, TIMER_ALL_ACCESS);
            std::size_t next_other = 0;
            std::vector<std::size_t> hot, others;
            for (std::size_t i = 0; i < threads.size(); ++i) (threads[i].role == 2 ? others : hot).push_back(i);
            while (!sampler_stop.load())
            {
                ++ticks;
                for (const auto index : hot) sample_thread(index);
                for (std::size_t n = 0; n < others_per_tick && !others.empty(); ++n)
                {
                    sample_thread(others[next_other]);
                    next_other = (next_other + 1) % others.size();
                }
                LARGE_INTEGER due{};
                due.QuadPart = -10000; // 1 ms in 100 ns units
                if (timer && SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE)) WaitForSingleObject(timer, 20);
                else Sleep(1);
            }
            if (timer) CloseHandle(timer);
        }
        void thread_times(thread_info& thread, const bool first)
        {
            FILETIME created{}, exited{}, kernel{}, user{};
            if (!GetThreadTimes(thread.handle, &created, &exited, &kernel, &user)) return;
            const auto k = (static_cast<ULONGLONG>(kernel.dwHighDateTime) << 32) | kernel.dwLowDateTime;
            const auto u = (static_cast<ULONGLONG>(user.dwHighDateTime) << 32) | user.dwLowDateTime;
            if (first) { thread.kernel0 = k; thread.user0 = u; }
            else { thread.kernel1 = k; thread.user1 = u; }
        }
        bool valid_name(const std::string& name)
        {
            return !name.empty() && name.size() <= 32 && name.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789_") == std::string::npos;
        }
        void begin(const std::string& name)
        {
            std::lock_guard<std::mutex> lock(window_mutex);
            if (window_open.load()) { console::error("[Paris perf] a window is already open: %s\n", window_name.c_str()); return; }
            if (!valid_name(name)) { console::error("[Paris perf] a window name is 1 to 32 characters of a-z, 0-9 and _\n"); return; }
            const auto main_id = main_thread.load(), render_id = render_thread.load();
            if (!main_id || !render_id) { console::error("[Paris perf] the main or the render thread is not known yet\n"); return; }
            threads.clear();
            stacks.clear();
            ticks = dropped = 0;
            const auto self = GetCurrentProcessId();
            const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
            if (snapshot != INVALID_HANDLE_VALUE)
            {
                THREADENTRY32 entry{};
                entry.dwSize = sizeof(entry);
                if (Thread32First(snapshot, &entry))
                {
                    do
                    {
                        if (entry.th32OwnerProcessID != self || threads.size() >= max_threads) continue;
                        thread_info info{};
                        info.id = entry.th32ThreadID;
                        info.role = info.id == main_id ? 0 : info.id == render_id ? 1 : 2;
                        info.handle = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, info.id);
                        if (!info.handle) continue;
                        thread_times(info, true);
                        threads.push_back(info);
                    } while (Thread32Next(snapshot, &entry));
                }
                CloseHandle(snapshot);
            }
            window_name = name;
            frame_qpc.clear();
            frame_qpc.reserve(1u << 16);
            sampler_stop = false;
            begin_qpc = now();
            window_open = true;
            sampler = std::thread([]
            {
                // The sampler never samples itself: it was created after the snapshot.
                sampler_loop();
            });
            console::info("[Paris perf] begin name=%s threads=%zu unwind=%d\n", name.c_str(), threads.size(), static_cast<int>(unwind_ready));
        }
        void hex(std::string& out, const std::uint64_t value)
        {
            char text[20]{};
            _snprintf_s(text, sizeof(text), _TRUNCATE, "%llX", static_cast<unsigned long long>(value));
            out += text;
        }
        void end()
        {
            std::lock_guard<std::mutex> lock(window_mutex);
            if (!window_open.load()) { console::error("[Paris perf] no window is open\n"); return; }
            window_open = false;
            end_qpc = now();
            sampler_stop = true;
            if (sampler.joinable()) sampler.join();
            for (auto& thread : threads) thread_times(thread, false);

            std::string out;
            out.reserve(1u << 20);
            const double seconds = static_cast<double>(end_qpc - begin_qpc) / static_cast<double>(qpc_hz);
            char line[512]{};
            _snprintf_s(line, sizeof(line), _TRUNCATE,
                "{\"schema\":\"iw7.perf-window/1\",\"name\":\"%s\",\"pid\":%lu,\"seconds\":%.6f,\"qpc_hz\":%lld,"
                "\"image\":{\"base\":\"%llX\",\"text_begin\":\"%llX\",\"text_end\":\"%llX\",\"unwind\":%s,\"functions\":%zu},\n",
                window_name.c_str(), GetCurrentProcessId(), seconds, static_cast<long long>(qpc_hz),
                static_cast<unsigned long long>(image_base), static_cast<unsigned long long>(text_begin), static_cast<unsigned long long>(text_end),
                unwind_ready ? "true" : "false", function_count);
            out += line;
            out += "\"frames_us\":[";
            for (std::size_t i = 1; i < frame_qpc.size(); ++i)
            {
                const auto us = (frame_qpc[i] - frame_qpc[i - 1]) * 1000000 / qpc_hz;
                if (i > 1) out += ',';
                out += std::to_string(us);
            }
            out += "],\n\"threads\":[";
            std::uint64_t samples = 0;
            for (std::size_t i = 0; i < threads.size(); ++i)
            {
                const auto& thread = threads[i];
                samples += thread.samples;
                _snprintf_s(line, sizeof(line), _TRUNCATE, "%s{\"id\":%lu,\"role\":\"%s\",\"user_ms\":%.3f,\"kernel_ms\":%.3f,\"samples\":%llu,\"failures\":%llu}",
                    i ? "," : "", thread.id, thread.role == 0 ? "main" : thread.role == 1 ? "render" : "other",
                    static_cast<double>(thread.user1 - thread.user0) / 10000.0, static_cast<double>(thread.kernel1 - thread.kernel0) / 10000.0,
                    static_cast<unsigned long long>(thread.samples), static_cast<unsigned long long>(thread.failures));
                out += line;
            }
            _snprintf_s(line, sizeof(line), _TRUNCATE, "],\n\"sampler\":{\"ticks\":%llu,\"hz\":%.1f,\"samples\":%llu,\"dropped\":%llu,\"others_per_tick\":%zu},\n\"stacks\":[",
                static_cast<unsigned long long>(ticks), seconds > 0 ? static_cast<double>(ticks) / seconds : 0.0,
                static_cast<unsigned long long>(samples), static_cast<unsigned long long>(dropped), others_per_tick);
            out += line;
            bool first = true;
            for (const auto& [key, count] : stacks)
            {
                const auto index = static_cast<unsigned char>(key[0]);
                const std::size_t depth = static_cast<unsigned char>(key[1]), scanned = static_cast<unsigned char>(key[2]);
                const auto* values = reinterpret_cast<const std::uint64_t*>(key.data() + 3);
                out += first ? "\n[" : ",\n[";
                first = false;
                out += std::to_string(index);
                out += ',';
                out += std::to_string(count);
                out += ",\"";
                for (std::size_t i = 0; i < depth; ++i) { if (i) out += ';'; hex(out, values[i]); }
                out += "\",\"";
                for (std::size_t i = 0; i < scanned; ++i) { if (i) out += ';'; hex(out, values[depth + i]); }
                out += "\"]";
            }
            out += "],\n\"modules\":[";
            HMODULE modules[512]{};
            DWORD needed{};
            if (EnumProcessModules(GetCurrentProcess(), modules, sizeof(modules), &needed))
            {
                const std::size_t count = needed / sizeof(HMODULE) < 512 ? needed / sizeof(HMODULE) : 512;
                for (std::size_t i = 0; i < count; ++i)
                {
                    MODULEINFO info{};
                    char name[MAX_PATH]{};
                    if (!GetModuleInformation(GetCurrentProcess(), modules[i], &info, sizeof(info))) continue;
                    if (!GetModuleBaseNameA(GetCurrentProcess(), modules[i], name, sizeof(name))) continue;
                    for (auto& c : name) if (c == '"' || c == '\\') c = '_';
                    _snprintf_s(line, sizeof(line), _TRUNCATE, "%s{\"base\":\"%llX\",\"size\":%lu,\"name\":\"%s\"}", i ? "," : "",
                        static_cast<unsigned long long>(reinterpret_cast<std::uintptr_t>(info.lpBaseOfDll)), info.SizeOfImage, name);
                    out += line;
                }
            }
            PROCESS_MEMORY_COUNTERS_EX memory{};
            memory.cb = sizeof(memory);
            GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&memory), sizeof(memory));
            _snprintf_s(line, sizeof(line), _TRUNCATE, "],\n\"memory\":{\"working_set\":%llu,\"private\":%llu}}\n",
                static_cast<unsigned long long>(memory.WorkingSetSize), static_cast<unsigned long long>(memory.PrivateUsage));
            out += line;
            for (auto& thread : threads) if (thread.handle) CloseHandle(thread.handle);
            const std::string path = "iw7-mod/paris-perf/" + window_name + ".json";
            const bool written = utils::io::write_file(path, out);
            console::info("[Paris perf] end name=%s seconds=%.3f frames=%zu samples=%llu stacks=%zu written=%d\n", window_name.c_str(), seconds,
                frame_qpc.size(), static_cast<unsigned long long>(samples), stacks.size(), static_cast<int>(written));
            threads.clear();
            stacks.clear();
        }
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (!utils::flags::has_flag("paris-perf") || !utils::flags::has_flag("paris-isolated-lab")) return;
            LARGE_INTEGER frequency{};
            QueryPerformanceFrequency(&frequency);
            qpc_hz = frequency.QuadPart;
            read_image();
            scheduler::loop([]
            {
                if (!render_thread.load()) render_thread = GetCurrentThreadId();
                if (window_open.load() && frame_qpc.size() < max_frames) frame_qpc.push_back(now());
            }, scheduler::renderer);
            scheduler::loop([]
            {
                if (!main_thread.load()) main_thread = GetCurrentThreadId();
            }, scheduler::main);
            command::add("paris_perf_begin", [](const command::params& params)
            {
                begin(params.size() > 1 ? params.get(1) : "");
            });
            command::add("paris_perf_end", [] { end(); });
            console::info("[Paris perf] ready unwind=%d functions=%zu\n", static_cast<int>(unwind_ready), function_count);
        }
        void pre_destroy() override
        {
            if (window_open.load())
            {
                sampler_stop = true;
                if (sampler.joinable()) sampler.join();
            }
        }
    };
}

REGISTER_COMPONENT(paris_perf::component)
