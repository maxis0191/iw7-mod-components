#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "scheduler.hpp"
#include "console/console.hpp"
#include "paris_stack.hpp"
#include <utils/flags.hpp>
#include <tlhelp32.h>
#include <psapi.h>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

// Freeze reporter for isolated lab builds (-paris-hang with -paris-isolated-lab). A client or a dedicated server.
//
// The game's main loop stores a heartbeat (the time of its last pass) on every pass. A watchdog thread wakes every
// 250 ms. When the heartbeat is older than the threshold (2000 ms, or PARIS_HANG_MS in the environment, 250..60000)
// the loop is frozen. The watchdog then records where the stuck thread is: its program counter and the call stack
// inside the game image, one sample every 500 ms (240 at most), and ONE sample of every other thread of the process at
// the start (a frozen thread usually waits for another one). When the heartbeat comes back, or after 120 s, it writes
//
//   iw7-mod/paris-hang/hang-<UTC yyyyMMddHHmmss>-<n>.json
//
// (schema iw7.hang/1). The main thread prints one line on its next pass. ops/engine-map/iw7_hang.py reads the file
// offline and names the addresses through the engine map. See docs/HANG.md.
//
// Sampler rule: between SuspendThread and ResumeThread the watchdog touches no heap, no file and no lock (see
// paris_stack.hpp). To keep the report safe even when the frozen thread holds the heap lock, the watchdog uses no heap
// for the report either: every buffer is static, the file is written with plain Win32 calls, and the console is never
// used from the watchdog. The thread list and the module list are taken BEFORE anything is suspended.
namespace paris_hang
{
    namespace
    {
        constexpr unsigned default_threshold_ms = 2000, min_threshold_ms = 250, max_threshold_ms = 60000;
        constexpr DWORD poll_ms = 250;
        constexpr std::int64_t sample_every_ms = 500, give_up_ms = 120000;
        constexpr std::size_t max_main_samples = 240, max_others = 200, max_modules = 512, max_files = 50;
        constexpr std::size_t buffer_size = 1u << 20;
        constexpr unsigned message_slots = 8;
        constexpr std::size_t message_size = 256;
        constexpr const char* output_directory = "iw7-mod/paris-hang";

        struct heartbeat
        {
            std::atomic<std::int64_t> qpc{0}; // time of the last pass; 0 until the first pass
            std::atomic<DWORD> thread{0};
        };
        struct timed_sample
        {
            std::int64_t ms{};
            paris_stack::raw_sample stack{};
        };
        struct thread_sample
        {
            DWORD id{};
            bool ok{};
            paris_stack::raw_sample stack{};
        };
        struct module_entry
        {
            std::uint64_t base{};
            DWORD size{};
            char name[64]{};
        };
        struct freeze_state
        {
            bool active{};
            int trigger{};                  // 0: main pipeline, 1: server pipeline
            std::int64_t stale_qpc{};       // the heartbeat value that stopped changing
            std::int64_t last_sample_qpc{};
            ULONGLONG began_filetime{};
            DWORD thread_id{};
            HANDLE handle{};
            bool sampling{};
            const char* not_sampled_reason{};
            bool server_stale{};
            bool written{};
            bool write_ok{};
            char iso[24]{};
            char compact[16]{};
            char file_name[96]{};
        };

        heartbeat beat_main, beat_server;
        bool enabled{};
        bool is_server{};
        unsigned threshold_ms{};
        std::int64_t qpc_hz{};
        HANDLE stop_event{};
        std::thread watchdog;

        // Messages from the watchdog to the main thread: one producer, one consumer, fixed slots.
        char message_text[message_slots][message_size];
        std::atomic<unsigned> message_head{0}, message_tail{0};

        // Watchdog thread only. All static: no heap while the process may be frozen.
        freeze_state freeze;
        DWORD watchdog_id{};
        unsigned files_written{}, file_sequence{}, suppressed{};
        timed_sample main_samples[max_main_samples];
        std::size_t main_count{};
        thread_sample other_samples[max_others];
        HANDLE other_handles[max_others];
        std::size_t other_count{};
        module_entry module_list[max_modules];
        std::size_t module_count{};
        char file_buffer[buffer_size];

        std::int64_t now()
        {
            LARGE_INTEGER value{};
            QueryPerformanceCounter(&value);
            return value.QuadPart;
        }
        std::int64_t to_ms(const std::int64_t ticks) { return ticks * 1000 / qpc_hz; }

        unsigned read_threshold()
        {
            char text[32]{};
            const DWORD length = GetEnvironmentVariableA("PARIS_HANG_MS", text, sizeof(text));
            if (length == 0 || length >= sizeof(text)) return default_threshold_ms;
            char* end{};
            const unsigned long value = std::strtoul(text, &end, 10);
            if (end == text || *end != '\0' || value < min_threshold_ms || value > max_threshold_ms) return default_threshold_ms;
            return static_cast<unsigned>(value);
        }

        // ---- main thread side ----
        void report_pending()
        {
            unsigned tail = message_tail.load(std::memory_order_relaxed);
            while (tail != message_head.load(std::memory_order_acquire))
            {
                console::info("%s", message_text[tail % message_slots]);
                ++tail;
                message_tail.store(tail, std::memory_order_release);
            }
        }
        void main_beat()
        {
            if (!beat_main.thread.load()) beat_main.thread.store(GetCurrentThreadId());
            beat_main.qpc.store(now());
            if (!is_server) report_pending();
        }
        void server_beat()
        {
            if (!beat_server.thread.load()) beat_server.thread.store(GetCurrentThreadId());
            beat_server.qpc.store(now());
            report_pending(); // on a server the server pipeline is the one that prints
        }

        // ---- watchdog thread side ----
        void enqueue_message(const char* format, ...)
        {
            const unsigned head = message_head.load(std::memory_order_relaxed);
            if (head - message_tail.load(std::memory_order_acquire) >= message_slots) return; // the main thread is not reading: drop
            va_list arguments;
            va_start(arguments, format);
            _vsnprintf_s(message_text[head % message_slots], message_size, _TRUNCATE, format, arguments);
            va_end(arguments);
            message_head.store(head + 1, std::memory_order_release);
        }

        struct writer
        {
            char* data{};
            std::size_t capacity{};
            std::size_t length{};
            bool overflow{};
        };
        void put(writer& out, const char* format, ...)
        {
            if (out.overflow) return;
            va_list arguments;
            va_start(arguments, format);
            const int written = _vsnprintf_s(out.data + out.length, out.capacity - out.length, _TRUNCATE, format, arguments);
            va_end(arguments);
            if (written < 0) out.overflow = true;
            else out.length += static_cast<std::size_t>(written);
        }
        void put_stack(writer& out, const paris_stack::raw_sample& sample)
        {
            put(out, "\"");
            for (std::uint32_t i = 0; i < sample.depth; ++i)
            {
                if (i) put(out, ";");
                put(out, "%llX", static_cast<unsigned long long>(sample.pc[i]));
            }
            put(out, "\",\"");
            for (std::uint32_t i = 0; i < sample.scanned; ++i)
            {
                if (i) put(out, ";");
                put(out, "%llX", static_cast<unsigned long long>(sample.scan[i]));
            }
            put(out, "\"");
        }

        void collect_modules()
        {
            module_count = 0;
            HMODULE modules[max_modules]{};
            DWORD needed{};
            if (!EnumProcessModules(GetCurrentProcess(), modules, sizeof(modules), &needed)) return;
            std::size_t count = needed / sizeof(HMODULE);
            if (count > max_modules) count = max_modules;
            for (std::size_t i = 0; i < count; ++i)
            {
                MODULEINFO info{};
                auto& entry = module_list[module_count];
                if (!GetModuleInformation(GetCurrentProcess(), modules[i], &info, sizeof(info))) continue;
                if (!GetModuleBaseNameA(GetCurrentProcess(), modules[i], entry.name, sizeof(entry.name))) continue;
                for (auto* c = entry.name; *c; ++c) if (*c == '"' || *c == '\\') *c = '_';
                entry.base = reinterpret_cast<std::uintptr_t>(info.lpBaseOfDll);
                entry.size = info.SizeOfImage;
                ++module_count;
            }
        }

        // Thread list and handles: taken before any thread is suspended.
        void collect_threads(const DWORD skip_a, const DWORD skip_b)
        {
            other_count = 0;
            const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
            if (snapshot == INVALID_HANDLE_VALUE) return;
            const DWORD self = GetCurrentProcessId();
            THREADENTRY32 entry{};
            entry.dwSize = sizeof(entry);
            if (Thread32First(snapshot, &entry))
            {
                do
                {
                    if (entry.th32OwnerProcessID != self || entry.th32ThreadID == skip_a || entry.th32ThreadID == skip_b) continue;
                    if (other_count >= max_others) break;
                    const HANDLE handle = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, entry.th32ThreadID);
                    if (!handle) continue;
                    other_samples[other_count].id = entry.th32ThreadID;
                    other_samples[other_count].ok = false;
                    other_handles[other_count] = handle;
                    ++other_count;
                } while (Thread32Next(snapshot, &entry));
            }
            CloseHandle(snapshot);
        }

        // Nothing but the capture between suspend and resume.
        bool suspend_capture(const HANDLE thread, paris_stack::raw_sample& out)
        {
            if (SuspendThread(thread) == static_cast<DWORD>(-1)) return false;
            const bool ok = paris_stack::capture(thread, out);
            ResumeThread(thread);
            return ok;
        }
        void sample_primary()
        {
            if (main_count >= max_main_samples) return;
            auto& slot = main_samples[main_count];
            const auto t = now();
            if (!suspend_capture(freeze.handle, slot.stack)) return;
            slot.ms = to_ms(t - freeze.stale_qpc);
            ++main_count;
        }
        void sample_others()
        {
            for (std::size_t i = 0; i < other_count; ++i)
            {
                other_samples[i].ok = suspend_capture(other_handles[i], other_samples[i].stack);
                CloseHandle(other_handles[i]);
                other_handles[i] = nullptr;
            }
        }

        bool write_file(const char* name, const char* data, const std::size_t size)
        {
            CreateDirectoryA("iw7-mod", nullptr);
            CreateDirectoryA(output_directory, nullptr);
            char path[192]{}, temporary[200]{};
            _snprintf_s(path, sizeof(path), _TRUNCATE, "%s/%s", output_directory, name);
            _snprintf_s(temporary, sizeof(temporary), _TRUNCATE, "%s.tmp", path);
            const HANDLE file = CreateFileA(temporary, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (file == INVALID_HANDLE_VALUE) return false;
            bool ok = true;
            std::size_t done = 0;
            while (ok && done < size)
            {
                DWORD wrote{};
                const DWORD chunk = static_cast<DWORD>(size - done > (1u << 20) ? (1u << 20) : size - done);
                ok = WriteFile(file, data + done, chunk, &wrote, nullptr) && wrote == chunk;
                done += wrote;
            }
            CloseHandle(file);
            if (ok) ok = MoveFileExA(temporary, path, MOVEFILE_REPLACE_EXISTING) != 0;
            else DeleteFileA(temporary);
            return ok;
        }

        void write_report(const bool still_frozen, const std::int64_t frozen_ms)
        {
            freeze.written = true;
            ++file_sequence;
            _snprintf_s(freeze.file_name, sizeof(freeze.file_name), _TRUNCATE, "hang-%s-%u.json", freeze.compact, file_sequence);
            writer out{file_buffer, buffer_size, 0, false};
            put(out, "{\"schema\":\"iw7.hang/1\",\"pid\":%lu,\"process\":\"%s\",\"began_utc\":\"%s\",\"frozen_ms\":%lld,\"threshold_ms\":%u,\"still_frozen\":%s,\n",
                GetCurrentProcessId(), is_server ? "server" : "client", freeze.iso, static_cast<long long>(frozen_ms), threshold_ms, still_frozen ? "true" : "false");
            put(out, "\"image\":{\"base\":\"%llX\",\"text_begin\":\"%llX\",\"text_end\":\"%llX\",\"unwind\":%s,\"functions\":%zu},\n",
                static_cast<unsigned long long>(paris_stack::image_base), static_cast<unsigned long long>(paris_stack::text_begin),
                static_cast<unsigned long long>(paris_stack::text_end), paris_stack::unwind_ready ? "true" : "false", paris_stack::function_count);
            put(out, "\"main_thread\":%lu,\"stalled_pipeline\":\"%s\",", freeze.thread_id, freeze.trigger == 0 ? "main" : "server");
            if (is_server) put(out, "\"server_pipeline_frozen\":%s,", freeze.server_stale ? "true" : "false");
            put(out, "\n\"samples\":[");
            for (std::size_t i = 0; i < main_count; ++i)
            {
                put(out, "%s\n[%lld,", i ? "," : "", static_cast<long long>(main_samples[i].ms));
                put_stack(out, main_samples[i].stack);
                put(out, "]");
            }
            put(out, "],\n\"others\":[");
            bool first = true;
            for (std::size_t i = 0; i < other_count; ++i)
            {
                if (!other_samples[i].ok || other_samples[i].stack.depth == 0) continue;
                put(out, "%s\n[%lu,", first ? "" : ",", other_samples[i].id);
                first = false;
                put_stack(out, other_samples[i].stack);
                put(out, "]");
            }
            put(out, "],\n\"modules\":[");
            for (std::size_t i = 0; i < module_count; ++i)
                put(out, "%s{\"base\":\"%llX\",\"size\":%lu,\"name\":\"%s\"}", i ? "," : "", static_cast<unsigned long long>(module_list[i].base),
                    module_list[i].size, module_list[i].name);
            put(out, "]}\n");
            freeze.write_ok = !out.overflow && write_file(freeze.file_name, file_buffer, out.length);
            if (freeze.write_ok) ++files_written;
        }

        void begin_freeze(const int trigger, const std::int64_t stale_value, const std::int64_t t)
        {
            freeze = freeze_state{};
            freeze.active = true;
            freeze.trigger = trigger;
            freeze.stale_qpc = stale_value;
            freeze.last_sample_qpc = t;
            freeze.thread_id = (trigger == 0 ? beat_main : beat_server).thread.load();
            freeze.server_stale = is_server && trigger == 1;
            if (is_server && !freeze.server_stale)
            {
                const auto server_value = beat_server.qpc.load();
                freeze.server_stale = server_value != 0 && to_ms(t - server_value) >= static_cast<std::int64_t>(threshold_ms);
            }

            FILETIME current{};
            GetSystemTimeAsFileTime(&current);
            ULARGE_INTEGER stamp{};
            stamp.LowPart = current.dwLowDateTime;
            stamp.HighPart = current.dwHighDateTime;
            const auto age = static_cast<ULONGLONG>(t - stale_value) * 10000000ull / static_cast<ULONGLONG>(qpc_hz);
            freeze.began_filetime = stamp.QuadPart > age ? stamp.QuadPart - age : stamp.QuadPart;
            ULARGE_INTEGER began{};
            began.QuadPart = freeze.began_filetime;
            FILETIME began_ft{};
            began_ft.dwLowDateTime = began.LowPart;
            began_ft.dwHighDateTime = began.HighPart;
            SYSTEMTIME time{};
            FileTimeToSystemTime(&began_ft, &time);
            _snprintf_s(freeze.iso, sizeof(freeze.iso), _TRUNCATE, "%04u-%02u-%02uT%02u:%02u:%02uZ", time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond);
            _snprintf_s(freeze.compact, sizeof(freeze.compact), _TRUNCATE, "%04u%02u%02u%02u%02u%02u", time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond);

            main_count = 0;
            other_count = 0;
            if (files_written >= max_files) { freeze.not_sampled_reason = "limit of 50 files reached"; return; }
            if (!freeze.thread_id) { freeze.not_sampled_reason = "thread unknown"; return; }
            // Everything that allocates comes first: modules, thread list, handles. Then the samples.
            collect_modules();
            freeze.handle = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, freeze.thread_id);
            if (!freeze.handle) { freeze.not_sampled_reason = "thread could not be opened"; return; }
            collect_threads(watchdog_id, freeze.thread_id);
            freeze.sampling = true;
            sample_primary();
            sample_others();
            freeze.last_sample_qpc = now();
        }

        void close_primary()
        {
            if (freeze.handle) { CloseHandle(freeze.handle); freeze.handle = nullptr; }
        }

        void end_freeze(const std::int64_t resumed_qpc)
        {
            const auto frozen_ms = to_ms(resumed_qpc - freeze.stale_qpc);
            if (freeze.sampling && !freeze.written) write_report(false, frozen_ms);
            close_primary();
            if (freeze.sampling && freeze.write_ok)
                enqueue_message("[Paris hang] main thread made no progress for %lld ms; written %s\n", static_cast<long long>(frozen_ms), freeze.file_name);
            else
            {
                ++suppressed;
                enqueue_message("[Paris hang] main thread made no progress for %lld ms; not written (%s; %u not written so far)\n", static_cast<long long>(frozen_ms),
                    freeze.sampling ? "file could not be written" : freeze.not_sampled_reason ? freeze.not_sampled_reason : "no sample", suppressed);
            }
            freeze = freeze_state{};
        }

        // The pipeline whose heartbeat is older than the threshold, or -1. The heartbeat value is returned too.
        int stale_pipeline(const std::int64_t t, std::int64_t& value)
        {
            const auto main_value = beat_main.qpc.load();
            if (main_value != 0 && to_ms(t - main_value) >= static_cast<std::int64_t>(threshold_ms)) { value = main_value; return 0; }
            if (is_server)
            {
                const auto server_value = beat_server.qpc.load();
                if (server_value != 0 && to_ms(t - server_value) >= static_cast<std::int64_t>(threshold_ms)) { value = server_value; return 1; }
            }
            return -1;
        }

        void watchdog_loop()
        {
            watchdog_id = GetCurrentThreadId();
            while (WaitForSingleObject(stop_event, poll_ms) == WAIT_TIMEOUT)
            {
                const auto t = now();
                if (!freeze.active)
                {
                    std::int64_t value{};
                    const int which = stale_pipeline(t, value);
                    if (which >= 0) begin_freeze(which, value, t);
                    continue;
                }
                const auto current = (freeze.trigger == 0 ? beat_main : beat_server).qpc.load();
                if (current != freeze.stale_qpc)
                {
                    end_freeze(current);
                    continue;
                }
                if (is_server && !freeze.server_stale)
                {
                    const auto server_value = beat_server.qpc.load();
                    if (server_value != 0 && to_ms(t - server_value) >= static_cast<std::int64_t>(threshold_ms)) freeze.server_stale = true;
                }
                if (!freeze.sampling || freeze.written) continue;
                const auto age = to_ms(t - freeze.stale_qpc);
                if (age >= give_up_ms)
                {
                    write_report(true, age);
                    close_primary();
                    continue;
                }
                if (to_ms(t - freeze.last_sample_qpc) >= sample_every_ms)
                {
                    sample_primary();
                    freeze.last_sample_qpc = now();
                }
            }
            close_primary();
        }
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (!utils::flags::has_flag("paris-hang") || !utils::flags::has_flag("paris-isolated-lab")) return;
            LARGE_INTEGER frequency{};
            QueryPerformanceFrequency(&frequency);
            qpc_hz = frequency.QuadPart;
            if (qpc_hz <= 0) return;
            is_server = game::environment::is_dedi();
            threshold_ms = read_threshold();
            paris_stack::read_image();
            stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!stop_event) return;
            scheduler::loop(main_beat, scheduler::main);
            if (is_server) scheduler::loop(server_beat, scheduler::server);
            watchdog = std::thread(watchdog_loop);
            enabled = true;
            console::info("[Paris hang] ready process=%s threshold_ms=%u unwind=%d\n", is_server ? "server" : "client", threshold_ms,
                static_cast<int>(paris_stack::unwind_ready));
        }
        void pre_destroy() override
        {
            if (!enabled) return;
            enabled = false;
            SetEvent(stop_event);
            if (watchdog.joinable()) watchdog.join();
            CloseHandle(stop_event);
            stop_event = nullptr;
        }
    };
}

REGISTER_COMPONENT(paris_hang::component)
