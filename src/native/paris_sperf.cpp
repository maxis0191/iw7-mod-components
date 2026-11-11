#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "command.hpp"
#include "console/console.hpp"
#include "game/game.hpp"
#include "scripting.hpp"
#include <utils/flags.hpp>
#include <utils/hook.hpp>
#include <utils/io.hpp>
#include <psapi.h>

// Server meter for isolated lab dedicated servers (-dedicated with -paris-isolated-lab; compiled only with -Perf).
//
//   paris_sperf_begin <name>   start a window
//   paris_sperf_end            stop it and write iw7-mod/paris-sperf/<name>.json
//
// A window holds:
// - every server frame: its start and its duration, timed around the function the engine runs once per server frame
//   (0x140B15E20, the call iw7-mod's scheduler wraps), with the performance counter;
// - a sampling profile of the script VM: about 1000 times a second the server thread is suspended and the VM's call
//   stack is read (scr_VmPub function frames, the running frame's position from scr_function_stack), outermost first;
// - the script function table (file, function, start of its code) so the reader names every position offline.
// Outside a window the frame timing is two counter reads and one flag test per server frame; nothing is sampled.
//
// Sampler rule (as paris_perf): between SuspendThread and ResumeThread it reads plain memory only: no heap, no file,
// no lock. A suspended thread may hold any of them.
namespace paris_sperf
{
    namespace
    {
        constexpr std::size_t max_frames = 1u << 20;
        constexpr std::size_t max_stacks = 200000;
        constexpr std::size_t max_depth = 32;
        constexpr std::uintptr_t server_frame_function = 0x140B15E20;

        utils::hook::detour server_frame_hook;
        std::atomic<DWORD> server_thread{0};
        std::atomic<bool> in_frame{false};
        std::atomic<bool> window_open{false};
        std::atomic<bool> sampler_stop{false};
        std::thread sampler;
        std::mutex window_mutex;  // begin/end only
        std::mutex frames_mutex;  // server thread push, end() read; never taken by the sampler
        std::vector<std::pair<std::int64_t, std::int64_t>> frames; // start and end, performance counter
        std::string window_name;
        std::int64_t qpc_hz{}, begin_qpc{}, end_qpc{};
        HANDLE sampled{};
        std::map<std::string, std::uint32_t> stacks; // key: in-frame byte, depth byte, then the positions, outermost first
        std::uint64_t ticks{}, idle{}, frame_only{}, script{}, failures{}, dropped{}, bad_frames{};

        std::int64_t now()
        {
            LARGE_INTEGER value{};
            QueryPerformanceCounter(&value);
            return value.QuadPart;
        }

        void server_frame_stub()
        {
            if (!server_thread.load(std::memory_order_relaxed)) server_thread = GetCurrentThreadId();
            const auto start = now();
            in_frame.store(true, std::memory_order_relaxed);
            server_frame_hook.invoke<void>();
            in_frame.store(false, std::memory_order_relaxed);
            if (!window_open.load(std::memory_order_acquire)) return;
            const auto end = now();
            std::lock_guard<std::mutex> lock(frames_mutex);
            if (frames.size() < max_frames) frames.emplace_back(start, end);
        }

        struct vm_sample
        {
            std::size_t depth{};
            std::uint64_t pos[max_depth]{};
            bool frame{};
        };

        // Reads the VM call stack of the suspended server thread. Plain reads, bounds checked: a frame pointer outside
        // the frame array (a thread caught while the VM moves it) is a failed sample, not a crash.
        bool read_vm(vm_sample& sample)
        {
            auto* pub = game::scr_VmPub.get();
            const auto* first = &pub->function_frame_start[0];
            const auto* last = &pub->function_frame_start[max_depth - 1];
            const auto* top = pub->function_frame;
            if (top < first || top > last) return false;
            sample.depth = static_cast<std::size_t>(top - first);
            // Frame k (1..depth) is the k-th call level; the running one keeps its position in scr_function_stack.
            for (std::size_t k = 1; k <= sample.depth; ++k)
            {
                const char* pos = k == sample.depth ? game::scr_function_stack->pos : first[k].fs.pos;
                sample.pos[k - 1] = reinterpret_cast<std::uint64_t>(pos);
            }
            return true;
        }

        void account(const vm_sample& sample)
        {
            std::string key;
            key.reserve(2 + sample.depth * 8);
            key.push_back(static_cast<char>(sample.frame ? 1 : 0));
            key.push_back(static_cast<char>(sample.depth));
            key.append(reinterpret_cast<const char*>(sample.pos), sample.depth * sizeof(std::uint64_t));
            const auto found = stacks.find(key);
            if (found != stacks.end()) ++found->second;
            else if (stacks.size() < max_stacks) stacks.emplace(std::move(key), 1u);
            else ++dropped;
        }

        void sampler_loop()
        {
            const HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, 0x00000002, TIMER_ALL_ACCESS);
            while (!sampler_stop.load())
            {
                ++ticks;
                vm_sample sample{};
                bool ok = false;
                if (SuspendThread(sampled) != static_cast<DWORD>(-1))
                {
                    // Only after the thread is stopped do the flag and the VM describe the same instant.
                    sample.frame = in_frame.load(std::memory_order_relaxed);
                    ok = read_vm(sample);
                    ResumeThread(sampled);
                }
                if (!ok) ++failures;
                else if (sample.depth) { ++script; account(sample); }
                else if (sample.frame) ++frame_only;
                else ++idle;
                LARGE_INTEGER due{};
                due.QuadPart = -10000; // 1 ms in 100 ns units
                if (timer && SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE)) WaitForSingleObject(timer, 20);
                else Sleep(1);
            }
            if (timer) CloseHandle(timer);
        }

        bool valid_name(const std::string& name)
        {
            return !name.empty() && name.size() <= 32 && name.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789_") == std::string::npos;
        }

        void begin(const std::string& name)
        {
            std::lock_guard<std::mutex> lock(window_mutex);
            if (window_open.load()) { console::error("[Paris sperf] a window is already open: %s\n", window_name.c_str()); return; }
            if (!valid_name(name)) { console::error("[Paris sperf] a window name is 1 to 32 characters of a-z, 0-9 and _\n"); return; }
            const auto id = server_thread.load();
            if (!id) { console::error("[Paris sperf] no server frame has run yet\n"); return; }
            sampled = OpenThread(THREAD_SUSPEND_RESUME | THREAD_QUERY_INFORMATION, FALSE, id);
            if (!sampled) { console::error("[Paris sperf] cannot open the server thread\n"); return; }
            stacks.clear();
            ticks = idle = frame_only = script = failures = dropped = bad_frames = 0;
            {
                std::lock_guard<std::mutex> frames_lock(frames_mutex);
                frames.clear();
                frames.reserve(1u << 14);
            }
            window_name = name;
            sampler_stop = false;
            begin_qpc = now();
            window_open = true;
            sampler = std::thread(sampler_loop);
            console::info("[Paris sperf] begin name=%s thread=%lu\n", name.c_str(), id);
        }

        void hex(std::string& out, const std::uint64_t value)
        {
            char text[20]{};
            _snprintf_s(text, sizeof(text), _TRUNCATE, "%llX", static_cast<unsigned long long>(value));
            out += text;
        }

        void quoted(std::string& out, const std::string& text)
        {
            out += '"';
            for (const auto c : text)
            {
                if (c == '"' || c == '\\') { out += '\\'; out += c; }
                else if (static_cast<unsigned char>(c) < 0x20) out += '?';
                else out += c;
            }
            out += '"';
        }

        void end()
        {
            std::lock_guard<std::mutex> lock(window_mutex);
            if (!window_open.load()) { console::error("[Paris sperf] no window is open\n"); return; }
            window_open = false;
            end_qpc = now();
            sampler_stop = true;
            if (sampler.joinable()) sampler.join();
            CloseHandle(sampled);
            sampled = nullptr;
            std::vector<std::pair<std::int64_t, std::int64_t>> taken;
            {
                std::lock_guard<std::mutex> frames_lock(frames_mutex);
                taken.swap(frames);
            }

            std::string out;
            out.reserve(1u << 22);
            const double seconds = static_cast<double>(end_qpc - begin_qpc) / static_cast<double>(qpc_hz);
            char line[512]{};
            _snprintf_s(line, sizeof(line), _TRUNCATE,
                "{\"schema\":\"iw7.server-perf/1\",\"name\":\"%s\",\"pid\":%lu,\"seconds\":%.6f,\"qpc_hz\":%lld,\"server_thread\":%lu,"
                "\"frame_function\":\"%llX\",\n\"frames_us\":[",
                window_name.c_str(), GetCurrentProcessId(), seconds, static_cast<long long>(qpc_hz), server_thread.load(),
                static_cast<unsigned long long>(server_frame_function));
            out += line;
            // Each frame: its start after the window began, and its duration, in microseconds.
            for (std::size_t i = 0; i < taken.size(); ++i)
            {
                if (i) out += ',';
                out += '[';
                out += std::to_string((taken[i].first - begin_qpc) * 1000000 / qpc_hz);
                out += ',';
                out += std::to_string((taken[i].second - taken[i].first) * 1000000 / qpc_hz);
                out += ']';
            }
            _snprintf_s(line, sizeof(line), _TRUNCATE,
                "],\n\"sampler\":{\"ticks\":%llu,\"hz\":%.1f,\"script\":%llu,\"frame_no_script\":%llu,\"idle\":%llu,\"failures\":%llu,\"dropped\":%llu},\n\"stacks\":[",
                static_cast<unsigned long long>(ticks), seconds > 0 ? static_cast<double>(ticks) / seconds : 0.0,
                static_cast<unsigned long long>(script), static_cast<unsigned long long>(frame_only), static_cast<unsigned long long>(idle),
                static_cast<unsigned long long>(failures), static_cast<unsigned long long>(dropped));
            out += line;
            bool first = true;
            for (const auto& [key, count] : stacks)
            {
                const std::size_t depth = static_cast<unsigned char>(key[1]);
                const auto* values = reinterpret_cast<const std::uint64_t*>(key.data() + 2);
                out += first ? "\n[" : ",\n[";
                first = false;
                out += std::to_string(count);
                out += key[0] ? ",1,\"" : ",0,\"";
                for (std::size_t i = 0; i < depth; ++i) { if (i) out += ';'; hex(out, values[i]); }
                out += "\"]";
            }
            // The function table iw7-mod keeps of every loaded script ("__end__" closes a file's code).
            out += "],\n\"scripts\":[";
            first = true;
            for (const auto& [file, functions] : scripting::script_function_table_sort)
            {
                out += first ? "\n{\"file\":" : ",\n{\"file\":";
                first = false;
                quoted(out, file);
                out += ",\"functions\":[";
                for (std::size_t i = 0; i < functions.size(); ++i)
                {
                    if (i) out += ',';
                    out += '[';
                    quoted(out, functions[i].first);
                    out += ",\"";
                    hex(out, reinterpret_cast<std::uint64_t>(functions[i].second));
                    out += "\"]";
                }
                out += "]}";
            }
            PROCESS_MEMORY_COUNTERS_EX memory{};
            memory.cb = sizeof(memory);
            GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&memory), sizeof(memory));
            _snprintf_s(line, sizeof(line), _TRUNCATE, "],\n\"memory\":{\"working_set\":%llu,\"private\":%llu}}\n",
                static_cast<unsigned long long>(memory.WorkingSetSize), static_cast<unsigned long long>(memory.PrivateUsage));
            out += line;
            const std::string path = "iw7-mod/paris-sperf/" + window_name + ".json";
            const bool written = utils::io::write_file(path, out);
            console::info("[Paris sperf] end name=%s seconds=%.3f frames=%zu ticks=%llu script=%llu stacks=%zu written=%d\n",
                window_name.c_str(), seconds, taken.size(), static_cast<unsigned long long>(ticks),
                static_cast<unsigned long long>(script), stacks.size(), static_cast<int>(written));
            stacks.clear();
        }
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (!game::environment::is_dedi() || !utils::flags::has_flag("paris-isolated-lab")) return;
            LARGE_INTEGER frequency{};
            QueryPerformanceFrequency(&frequency);
            qpc_hz = frequency.QuadPart;
            server_frame_hook.create(server_frame_function, server_frame_stub);
            command::add("paris_sperf_begin", [](const command::params& params)
            {
                begin(params.size() > 1 ? params.get(1) : "");
            });
            command::add("paris_sperf_end", [] { end(); });
            console::info("[Paris sperf] ready\n");
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

REGISTER_COMPONENT(paris_sperf::component)
