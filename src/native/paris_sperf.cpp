#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "command.hpp"
#include "console/console.hpp"
#include "game/game.hpp"
#include "scripting.hpp"
#include <utils/flags.hpp>
#include <utils/hook.hpp>
#include <utils/io.hpp>
#include "paris_log_stream.hpp"
#include <psapi.h>
#include <intrin.h>
#include <algorithm>

// Server meter for isolated lab dedicated servers (-dedicated with -paris-isolated-lab; compiled only with -Perf).
//
//   paris_sperf_begin <name>   start a window
//   paris_sperf_begin <name> light   the same without the sampler thread: frame times and the snapshot counters only
//   paris_sperf_end            stop it and write iw7-mod/paris-sperf/<name>.json
//   paris_fr_slow <ms>         the slow-frame watchdog of the flight recorder (0 = off, the default). A server frame that runs longer
//                              than <ms> is sampled while it is still running (a thread that wakes every 4 ms, reads one atomic and,
//                              inside a slow frame only, suspends the server thread for one VM stack read as the sampler does) and
//                              the frame's end prints one line: [FR] t=<level time> native_slow_frame ms=<n> ...
//
// A window holds:
// - every server frame: its start and its duration, timed around the game's frame function of the multiplayer/CP game
//   module (0x140B213F0, G_RunFrame: takes the level time, stores it, counts the frame, runs the script VM's threads and
//   iw7-mod's server scheduler pipeline), with the performance counter;
// - a sampling profile of the script VM: about 1000 times a second the server thread is suspended and the VM's call
//   stack is read (scr_VmPub function frames, the running frame's position from scr_function_stack), outermost first;
// - the snapshot entity counts (read only, no cap is changed): the entity records one client's snapshot list holds (FUN_140C67230
//   writes it; the count is the local at [rsp+0x40] of its frame, read in the call that closes the list with 0x7FF at
//   0x140C6765B) and the two common lists of the frame (FUN_140C64310 returns the count of the all-client list, FUN_140C647A0
//   built the list of entities above 17, whose count stays in [0x146B39830]; it is built once after a reset, not every frame, so it is
//   read once per frame in the list A hook). Per list: calls, max, mean and how many times the
//   count had reached the cap (768, 1024, 1024: the list was closed early). Every hook is verified against the expected
//   code bytes first and is left out, with an error line, when they differ;
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
        constexpr std::uintptr_t server_frame_function = 0x140B213F0; // G_RunFrame (int level_time)

        utils::hook::detour server_frame_hook;
        std::atomic<DWORD> server_thread{0};
        std::atomic<bool> in_frame{false};
        std::atomic<bool> window_open{false};
        std::atomic<bool> sampler_stop{false};
        std::atomic<bool> light_window{false};
        std::thread sampler;
        std::mutex window_mutex;  // begin/end only
        std::mutex frames_mutex;  // server thread push, end() read; never taken by the sampler
        std::vector<std::pair<std::int64_t, std::int64_t>> frames; // start and end, performance counter
        std::string window_name;
        std::int64_t qpc_hz{}, begin_qpc{}, end_qpc{};
        HANDLE sampled{};
        std::map<std::string, std::uint32_t> stacks; // key: in-frame byte, depth byte, then the positions, outermost first
        std::uint64_t ticks{}, idle{}, frame_only{}, script{}, failures{}, dropped{}, bad_frames{};

        // Snapshot entity counts. Written by the server thread only while a window is open; end() reads them after the window closed.
        constexpr std::uintptr_t snapshot_close_call = 0x140C6765B;  // call FUN_140BC2D70 (write 0x7FF in 11 bits) in FUN_140C67230
        constexpr std::uintptr_t snapshot_cap_compare = 0x140C67478; // cmp eax,[sv_maxSnapshotEntities] in FUN_140C67230
        constexpr std::uintptr_t common_a_function = 0x140C64310;    // int FUN_140C64310(): count of the all-client list
        constexpr std::uintptr_t cap_snapshot = 0x146B3985C;         // sv_maxSnapshotEntities (768)
        constexpr std::uintptr_t cap_common_a = 0x146B39858;         // 1024
        constexpr std::uintptr_t cap_common_b = 0x146B39860;         // 1024
        constexpr std::uintptr_t common_b_count = 0x146B39830;       // count of the list FUN_140C647A0 builds (once per reset of FUN_140C64BA0, not per frame)

        struct count_meter
        {
            std::atomic<std::uint64_t> calls{}, sum{}, maximum{}, capped{};
            std::atomic<int> cap{};
            void reset() { calls = 0; sum = 0; maximum = 0; capped = 0; }
            void add(const int count, const int limit)
            {
                if (count < 0) return;
                ++calls;
                sum += static_cast<std::uint64_t>(count);
                cap = limit;
                auto seen = maximum.load(std::memory_order_relaxed);
                while (static_cast<std::uint64_t>(count) > seen && !maximum.compare_exchange_weak(seen, static_cast<std::uint64_t>(count))) {}
                if (limit > 0 && count >= limit) ++capped;
            }
            void write(std::string& out, const char* name, const bool first) const
            {
                char text[200]{};
                const auto n = calls.load();
                _snprintf_s(text, sizeof(text), _TRUNCATE, "%s\"%s\":{\"calls\":%llu,\"max\":%llu,\"mean\":%.3f,\"capped\":%llu,\"cap\":%d}",
                    first ? "" : ",", name, static_cast<unsigned long long>(n), static_cast<unsigned long long>(maximum.load()),
                    n ? static_cast<double>(sum.load()) / static_cast<double>(n) : 0.0, static_cast<unsigned long long>(capped.load()), cap.load());
                out += text;
            }
        };
        count_meter snapshot_meter, common_a_meter, common_b_meter;
        utils::hook::detour common_a_hook;

        int read_int(const std::uintptr_t address) { return *reinterpret_cast<const volatile int*>(address); }

        // Replaces the call at 0x140C6765B in FUN_140C67230: FUN_140BC2D70(message, value, bits) runs unchanged after the read.
        // That call's frame is _AddressOfReturnAddress() + 8, and the entity records written so far are its dword at [rsp+0x40].
        __declspec(noinline) void snapshot_close_stub(void* message, const int value, const int bits)
        {
            if (window_open.load(std::memory_order_acquire))
            {
                const auto* frame = static_cast<const char*>(_AddressOfReturnAddress()) + 8;
                snapshot_meter.add(*reinterpret_cast<const int*>(frame + 0x40), read_int(cap_snapshot));
            }
            reinterpret_cast<void(*)(void*, int, int)>(0x140BC2D70)(message, value, bits);
        }

        int common_a_stub()
        {
            const int count = common_a_hook.invoke<int>();
            if (window_open.load(std::memory_order_acquire))
            {
                common_a_meter.add(count, read_int(cap_common_a));
                common_b_meter.add(read_int(common_b_count), read_int(cap_common_b)); // sampled once per frame here
            }
            return count;
        }

        bool code_is(const std::uintptr_t address, const char* name, const unsigned char* expected, const std::size_t size)
        {
            if (std::memcmp(reinterpret_cast<const void*>(address), expected, size) == 0) return true;
            console::error("[Paris sperf] %s at 0x%llX: code differs from the expected bytes, its counter is left out\n", name,
                static_cast<unsigned long long>(address));
            return false;
        }

        void install_snapshot_counters()
        {
            static const unsigned char close_call[] = {0xE8, 0x10, 0xB7, 0xF5, 0xFF};
            static const unsigned char cap_compare[] = {0x3B, 0x05, 0xDE, 0x23, 0xED, 0x05};
            static const unsigned char common_a_code[] = {0x48, 0x89, 0x6C, 0x24, 0x10, 0x48, 0x89, 0x74, 0x24, 0x18, 0x48, 0x89, 0x7C, 0x24, 0x20, 0x41};
            int installed = 0;
            if (code_is(snapshot_close_call, "snapshot list close", close_call, sizeof(close_call)) &&
                code_is(snapshot_cap_compare, "snapshot cap compare", cap_compare, sizeof(cap_compare)))
            {
                utils::hook::call(snapshot_close_call, snapshot_close_stub);
                ++installed;
            }
            if (code_is(common_a_function, "common list A", common_a_code, sizeof(common_a_code)))
            {
                common_a_hook.create(common_a_function, common_a_stub);
                ++installed;
            }
            console::info("[Paris sperf] snapshot counters installed=%d of 2\n", installed);
        }

        // CPU time of the whole process (user + kernel), in seconds: a window's cost is the difference between its two ends.
        double process_cpu_seconds()
        {
            FILETIME created{}, exited{}, kernel{}, user{};
            if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)) return 0.0;
            const auto filetime_ticks = [](const FILETIME& t) { return static_cast<double>((static_cast<std::uint64_t>(t.dwHighDateTime) << 32) | static_cast<std::uint64_t>(t.dwLowDateTime)); };
            return (filetime_ticks(kernel) + filetime_ticks(user)) / 1.0e7;
        }
        double window_cpu_begin{};

        // A flight-recorder line. console::info costs about 0.16 ms for every byte on the lab server (measured 16 Nov 2026, 200 alive: a 1,300 byte line added
        // 215 ms to the frame), so the line goes to the game log through the buffered handle G_LogPrintf uses (paris_log_stream: one write a server frame), where the
        // script recorder's lines are too; console::info only when that file cannot be written.
        void flight_line(const char* text)
        {
            if (paris_log_stream::instance().append("iw7-mod/logs/games_mp.log", text)) return;
            console::info("%s", text);
        }

        std::int64_t now()
        {
            LARGE_INTEGER value{};
            QueryPerformanceCounter(&value);
            return value.QuadPart;
        }

        // Slow-frame watchdog (the flight recorder, docs/SERVER-PERF.md "Slow frames"). Off until paris_fr_slow <ms> is given.
        std::atomic<int> slow_limit_ms{0};
        std::atomic<std::int64_t> frame_start_qpc{0};
        std::atomic<std::uint64_t> frame_serial{0};
        std::atomic<std::uint64_t> slow_frames{0};
        std::atomic<bool> watchdog_stop{false};
        std::atomic<bool> watchdog_running{false};
        std::thread watchdog;

        void report_slow_frame(int level_time, std::int64_t start, std::int64_t end, std::uint64_t serial);

        void server_frame_stub(const int level_time)
        {
            if (!server_thread.load(std::memory_order_relaxed)) server_thread = GetCurrentThreadId();
            const auto start = now();
            const auto serial = frame_serial.fetch_add(1, std::memory_order_relaxed) + 1;
            frame_start_qpc.store(start, std::memory_order_relaxed);
            in_frame.store(true, std::memory_order_relaxed);
            server_frame_hook.invoke<void>(level_time);
            in_frame.store(false, std::memory_order_relaxed);
            const auto limit = slow_limit_ms.load(std::memory_order_relaxed);
            const bool recording = window_open.load(std::memory_order_acquire);
            if (limit <= 0 && !recording) return;
            const auto end = now();
            if (limit > 0 && (end - start) * 1000 >= static_cast<std::int64_t>(limit) * qpc_hz) report_slow_frame(level_time, start, end, serial);
            if (!recording) return;
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
            std::uint64_t random = 0x9E3779B97F4A7C15ull ^ static_cast<std::uint64_t>(now());
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
                // The timer wakes on the system timer's grid, and so does the server's frame wait (50 ms is a whole number
                // of grid steps): without a random offset every sample falls at the same few instants of a server frame
                // and a short burst of script is missed or always hit (first live run: 4,000 iterations read 13 ns each,
                // 70,000 read 170 ns). A random spin of 0 to 1 ms spreads the samples over the frame.
                random ^= random << 13; random ^= random >> 7; random ^= random << 17;
                const auto until = now() + static_cast<std::int64_t>(random % 1000) * qpc_hz / 1000000;
                while (now() < until) YieldProcessor();
            }
            if (timer) CloseHandle(timer);
        }

        // ---- slow-frame watchdog -------------------------------------------------------------------------------------------
        std::mutex slow_mutex;                       // watchdog (after it resumed the thread) and the server thread at the end of a frame
        std::vector<vm_sample> slow_samples;         // VM stacks read inside the frame whose serial is slow_serial
        std::uint64_t slow_serial{};
        std::uint64_t slow_script_samples{}, slow_engine_samples{};
        constexpr std::size_t max_slow_samples = 12;

        void watchdog_loop()
        {
            const HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, 0x00000002, TIMER_ALL_ACCESS);
            HANDLE thread = nullptr;
            while (!watchdog_stop.load())
            {
                LARGE_INTEGER due{};
                due.QuadPart = -40000; // 4 ms
                if (timer && SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE)) WaitForSingleObject(timer, 20);
                else Sleep(4);
                const auto limit = slow_limit_ms.load(std::memory_order_relaxed);
                if (limit <= 0 || !in_frame.load(std::memory_order_relaxed)) continue;
                const auto serial = frame_serial.load(std::memory_order_relaxed);
                const auto start = frame_start_qpc.load(std::memory_order_relaxed);
                if ((now() - start) * 1000 < static_cast<std::int64_t>(limit) * qpc_hz) continue;
                if (!thread)
                {
                    const auto id = server_thread.load();
                    if (!id) continue;
                    thread = OpenThread(THREAD_SUSPEND_RESUME | THREAD_QUERY_INFORMATION, FALSE, id);
                    if (!thread) continue;
                }
                {
                    std::lock_guard<std::mutex> lock(slow_mutex);
                    if (slow_serial == serial && slow_samples.size() >= max_slow_samples) continue;
                }
                vm_sample sample{};
                bool ok = false, inside = false;
                std::uint64_t seen = 0;
                if (SuspendThread(thread) != static_cast<DWORD>(-1))
                {
                    inside = in_frame.load(std::memory_order_relaxed);
                    seen = frame_serial.load(std::memory_order_relaxed);
                    ok = read_vm(sample);
                    ResumeThread(thread);
                }
                if (!ok || !inside || seen != serial) continue;
                std::lock_guard<std::mutex> lock(slow_mutex);
                if (slow_serial != serial) { slow_samples.clear(); slow_serial = serial; slow_script_samples = slow_engine_samples = 0; }
                if (sample.depth) ++slow_script_samples; else ++slow_engine_samples;
                if (sample.depth && slow_samples.size() < max_slow_samples) slow_samples.push_back(sample);
            }
            if (thread) CloseHandle(thread);
            if (timer) CloseHandle(timer);
        }

        // Code position -> "file::function" through the function table iw7-mod keeps (the same table the window file carries).
        // Built once per set of loaded scripts, searched by position.
        struct function_row { std::uintptr_t start; const std::string* file; const std::string* name; };
        std::vector<function_row> function_rows;
        std::size_t function_rows_files = ~static_cast<std::size_t>(0);

        std::string function_at(const std::uint64_t position)
        {
            if (function_rows_files != scripting::script_function_table_sort.size())
            {
                function_rows.clear();
                for (const auto& [file, functions] : scripting::script_function_table_sort)
                    for (const auto& entry : functions)
                        function_rows.push_back({reinterpret_cast<std::uintptr_t>(entry.second), &file, &entry.first});
                std::sort(function_rows.begin(), function_rows.end(), [](const function_row& a, const function_row& b) { return a.start < b.start; });
                function_rows_files = scripting::script_function_table_sort.size();
            }
            const auto at = std::upper_bound(function_rows.begin(), function_rows.end(), position, [](const std::uint64_t value, const function_row& row) { return value < row.start; });
            if (at == function_rows.begin()) return "?";
            const auto& row = *(at - 1);
            if (*row.name == "__end__") return "?";
            std::string file = *row.file;
            const auto slash = file.find_last_of("/\\");
            if (slash != std::string::npos) file = file.substr(slash + 1);
            return file + "::" + *row.name;
        }

        // Server thread, at the end of a frame that took longer than the limit: one line with what the watchdog saw inside it.
        void report_slow_frame(const int level_time, const std::int64_t start, const std::int64_t end, const std::uint64_t serial)
        {
            ++slow_frames;
            std::vector<vm_sample> taken;
            std::uint64_t script_n = 0, engine_n = 0;
            {
                std::lock_guard<std::mutex> lock(slow_mutex);
                if (slow_serial == serial) { taken.swap(slow_samples); script_n = slow_script_samples; engine_n = slow_engine_samples; }
            }
            std::map<std::string, int> leaves, roots;
            for (const auto& sample : taken)
            {
                ++leaves[function_at(sample.pos[sample.depth - 1])];
                ++roots[function_at(sample.pos[0])];
            }
            auto join = [](const std::map<std::string, int>& counts)
            {
                std::vector<std::pair<int, std::string>> ordered;
                for (const auto& [name, n] : counts) ordered.emplace_back(n, name);
                std::sort(ordered.begin(), ordered.end(), [](const auto& a, const auto& b) { return a.first > b.first; });
                std::string out;
                for (std::size_t i = 0; i < ordered.size() && i < 3; ++i) { if (i) out += ','; out += ordered[i].second + "*" + std::to_string(ordered[i].first); }
                return out.empty() ? std::string("-") : out;
            };
            char text[900]{};
            _snprintf_s(text, sizeof(text), _TRUNCATE,
                "[FR] t=%d native_slow_frame ms=%.1f serial=%llu samples=%llu script=%llu engine=%llu leaf=%s thread=%s\n",
                level_time, static_cast<double>(end - start) * 1000.0 / static_cast<double>(qpc_hz), static_cast<unsigned long long>(serial),
                static_cast<unsigned long long>(script_n + engine_n), static_cast<unsigned long long>(script_n), static_cast<unsigned long long>(engine_n),
                join(leaves).c_str(), join(roots).c_str());
            flight_line(text);
        }

        void set_slow_limit(const int ms)
        {
            slow_limit_ms = ms < 0 ? 0 : ms;
            if (ms > 0 && !watchdog_running.exchange(true))
            {
                watchdog_stop = false;
                watchdog = std::thread(watchdog_loop);
            }
            console::info("[Paris sperf] paris_fr_slow=%d slow_frames_so_far=%llu\n", slow_limit_ms.load(), static_cast<unsigned long long>(slow_frames.load()));
        }

        bool valid_name(const std::string& name)
        {
            return !name.empty() && name.size() <= 32 && name.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789_") == std::string::npos;
        }

        void begin(const std::string& name, const bool light)
        {
            std::lock_guard<std::mutex> lock(window_mutex);
            if (window_open.load()) { console::error("[Paris sperf] a window is already open: %s\n", window_name.c_str()); return; }
            if (!valid_name(name)) { console::error("[Paris sperf] a window name is 1 to 32 characters of a-z, 0-9 and _\n"); return; }
            const auto id = server_thread.load();
            if (!id) { console::error("[Paris sperf] no server frame has run yet\n"); return; }
            sampled = OpenThread(THREAD_SUSPEND_RESUME | THREAD_QUERY_INFORMATION, FALSE, id);
            if (!sampled) { console::error("[Paris sperf] cannot open the server thread\n"); return; }
            stacks.clear();
            snapshot_meter.reset(); common_a_meter.reset(); common_b_meter.reset();
            ticks = idle = frame_only = script = failures = dropped = bad_frames = 0;
            {
                std::lock_guard<std::mutex> frames_lock(frames_mutex);
                frames.clear();
                frames.reserve(1u << 14);
            }
            window_name = name;
            sampler_stop = false;
            light_window = light;
            window_cpu_begin = process_cpu_seconds();
            begin_qpc = now();
            window_open = true;
            if (!light) sampler = std::thread(sampler_loop);
            console::info("[Paris sperf] begin name=%s thread=%lu mode=%s\n", name.c_str(), id, light ? "light" : "sampled");
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
            const double window_cpu = process_cpu_seconds() - window_cpu_begin;
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
                "{\"schema\":\"iw7.server-perf/1\",\"name\":\"%s\",\"pid\":%lu,\"seconds\":%.6f,\"qpc_hz\":%lld,\"begin_qpc\":%lld,\"end_qpc\":%lld,\"server_thread\":%lu,"
                "\"frame_function\":\"%llX\",\n\"frames_us\":[",
                window_name.c_str(), GetCurrentProcessId(), seconds, static_cast<long long>(qpc_hz), static_cast<long long>(begin_qpc), static_cast<long long>(end_qpc), server_thread.load(),
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
            out += "],\n\"snapshot\":{";
            snapshot_meter.write(out, "entities", true);
            common_a_meter.write(out, "common_a", false);
            common_b_meter.write(out, "common_b", false);
            _snprintf_s(line, sizeof(line), _TRUNCATE,
                "},\n\"sampler\":{\"mode\":\"%s\",\"ticks\":%llu,\"hz\":%.1f,\"script\":%llu,\"frame_no_script\":%llu,\"idle\":%llu,\"failures\":%llu,\"dropped\":%llu},\n\"stacks\":[",
                light_window.load() ? "light" : "sampled", static_cast<unsigned long long>(ticks), seconds > 0 ? static_cast<double>(ticks) / seconds : 0.0,
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
            _snprintf_s(line, sizeof(line), _TRUNCATE, "],\n\"cpu_seconds\":%.4f,\n\"memory\":{\"working_set\":%llu,\"private\":%llu}}\n",
                window_cpu, static_cast<unsigned long long>(memory.WorkingSetSize), static_cast<unsigned long long>(memory.PrivateUsage));
            out += line;
            const std::string path = "iw7-mod/paris-sperf/" + window_name + ".json";
            const bool written = utils::io::write_file(path, out);
            console::info("[Paris sperf] end name=%s mode=%s seconds=%.3f cpu_seconds=%.3f frames=%zu ticks=%llu script=%llu stacks=%zu written=%d\n",
                window_name.c_str(), light_window.load() ? "light" : "sampled", seconds, window_cpu, taken.size(), static_cast<unsigned long long>(ticks),
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
            install_snapshot_counters();
            command::add("paris_sperf_begin", [](const command::params& params)
            {
                begin(params.size() > 1 ? params.get(1) : "", params.size() > 2 && std::string(params.get(2)) == "light");
            });
            command::add("paris_fr_slow", [](const command::params& params)
            {
                set_slow_limit(params.size() > 1 ? std::atoi(params.get(1)) : 0);
            });
            command::add("paris_sperf_end", [] { end(); });
            console::info("[Paris sperf] ready\n");
        }

        void pre_destroy() override
        {
            watchdog_stop = true;
            if (watchdog.joinable()) watchdog.join();
            if (window_open.load())
            {
                sampler_stop = true;
                if (sampler.joinable()) sampler.join();
            }
        }
    };
}

REGISTER_COMPONENT(paris_sperf::component)
