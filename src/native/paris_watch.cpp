#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "scheduler.hpp"
#include "console/console.hpp"
#include "paris_watch.hpp"
#include <utils/flags.hpp>
#include <cstring>
#include <fstream>
#include <memory>
#include <new>

// Memory watch for isolated lab clients (-paris-watch with -paris-isolated-lab).
//
// paris_watch::start(address, size, interval_ms, count) copies a block of the game's own memory `count` times, one copy
// every `interval_ms`, into one buffer. Every copy is made on the main thread, inside a pass of the main loop, so the
// block is consistent with the game's own main-thread writes. Page by page: a page that is not committed or not
// readable is filled with zero and counted. When the last copy is taken, a writer thread writes
//
//   iw7-mod/paris-watch/watch-<address hex>-<UTC yyyyMMddHHmmss>.bin
//
// a JSON header line (schema iw7.memory-watch/1) followed by the raw copies back to back. ops/engine-map/iw7_watch.py
// reads it offline.
//
// Rules: the buffer and the arrays are allocated in start(), never later. The main thread never writes a file. The
// console is used from the main thread only. The writer thread is created at start-up and joined in pre_destroy.
namespace paris_watch
{
    namespace
    {
        constexpr std::size_t min_size = 16, max_size = 4194304;
        constexpr unsigned min_interval = 10, max_interval = 5000, min_count = 2, max_count = 600;
        constexpr std::uint64_t max_total = 268435456;
        constexpr std::size_t page = 0x1000;
        constexpr const char* output_directory = "iw7-mod/paris-watch";

        struct job
        {
            std::unique_ptr<std::uint8_t[]> data;
            std::vector<std::int64_t> stamps;
            std::vector<std::uint32_t> unreadable;
            std::uintptr_t address{};
            std::size_t size{};
            unsigned interval_ms{};
            unsigned count{};
            std::size_t taken{};
            std::int64_t next_due{};
        };
        struct result
        {
            bool ok{};
            std::string name;
            std::uint64_t bytes{};
        };

        bool enabled{};
        bool busy{}; // main thread only: from start() until the written line is printed
        std::unique_ptr<job> current; // main thread only
        std::int64_t qpc_hz{};

        std::mutex hand_mutex;
        std::unique_ptr<job> pending;
        result finished;
        std::atomic<bool> finished_ready{false};
        std::atomic<bool> writer_stop{false};
        std::thread writer;
        HANDLE wake{};

        std::int64_t now()
        {
            LARGE_INTEGER value{};
            QueryPerformanceCounter(&value);
            return value.QuadPart;
        }

        // POD only: SEH guards a page that is freed between the check and the copy.
        __declspec(noinline) bool guarded_copy(void* destination, const void* source, const std::size_t size)
        {
            __try
            {
                std::memcpy(destination, source, size);
                return true;
            }
            __except (EXCEPTION_EXECUTE_HANDLER)
            {
                return false;
            }
        }

        // One copy of the block into `destination`. Returns the number of pages that could not be read (filled with zero).
        std::uint32_t copy_block(std::uint8_t* destination, const std::uintptr_t address, const std::size_t size)
        {
            std::uint32_t unreadable = 0;
            std::size_t done = 0;
            std::uintptr_t region_end = 0;
            bool region_readable = false;
            while (done < size)
            {
                const auto current_address = address + done;
                std::size_t chunk = page - (current_address & (page - 1));
                if (chunk > size - done) chunk = size - done;
                if (current_address >= region_end)
                {
                    MEMORY_BASIC_INFORMATION info{};
                    if (VirtualQuery(reinterpret_cast<const void*>(current_address), &info, sizeof(info)))
                    {
                        region_end = reinterpret_cast<std::uintptr_t>(info.BaseAddress) + info.RegionSize;
                        region_readable = info.State == MEM_COMMIT && !(info.Protect & (PAGE_NOACCESS | PAGE_GUARD));
                    }
                    else
                    {
                        region_end = current_address + chunk;
                        region_readable = false;
                    }
                }
                if (!region_readable || !guarded_copy(destination + done, reinterpret_cast<const void*>(current_address), chunk))
                {
                    std::memset(destination + done, 0, chunk);
                    ++unreadable;
                }
                done += chunk;
            }
            return unreadable;
        }

        std::string file_stem(const job& item)
        {
            SYSTEMTIME time{};
            GetSystemTime(&time);
            char name[96]{};
            _snprintf_s(name, sizeof(name), _TRUNCATE, "watch-%llX-%04u%02u%02u%02u%02u%02u", static_cast<unsigned long long>(item.address),
                time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond);
            return name;
        }

        bool write_file(const job& item, std::string& name_out, std::uint64_t& bytes_out)
        {
            CreateDirectoryA("iw7-mod", nullptr);
            CreateDirectoryA(output_directory, nullptr);
            const std::string stem = file_stem(item);
            std::string name = stem + ".bin";
            // Two recordings of one block inside the same second must not overwrite each other.
            for (int suffix = 2; suffix < 100 && GetFileAttributesA((std::string(output_directory) + "/" + name).c_str()) != INVALID_FILE_ATTRIBUTES; ++suffix)
                name = stem + "-" + std::to_string(suffix) + ".bin";
            const std::string path = std::string(output_directory) + "/" + name;
            const std::string temporary = path + ".tmp";

            std::string header;
            header.reserve(256 + item.count * 24);
            char line[256]{};
            _snprintf_s(line, sizeof(line), _TRUNCATE,
                "{\"schema\":\"iw7.memory-watch/1\",\"address\":\"%llX\",\"size\":%zu,\"count\":%u,\"interval_ms\":%u,\"qpc_hz\":%lld,\"timestamps\":[",
                static_cast<unsigned long long>(item.address), item.size, item.count, item.interval_ms, static_cast<long long>(qpc_hz));
            header += line;
            for (std::size_t i = 0; i < item.stamps.size(); ++i)
            {
                if (i) header += ',';
                header += std::to_string(item.stamps[i]);
            }
            header += "],\"unreadable_pages\":[";
            for (std::size_t i = 0; i < item.unreadable.size(); ++i)
            {
                if (i) header += ',';
                header += std::to_string(item.unreadable[i]);
            }
            _snprintf_s(line, sizeof(line), _TRUNCATE, "],\"pid\":%lu}\n", GetCurrentProcessId());
            header += line;

            bool ok = false;
            {
                std::ofstream out(temporary, std::ios::binary | std::ios::trunc);
                if (out)
                {
                    out.write(header.data(), static_cast<std::streamsize>(header.size()));
                    // The samples go out one at a time: nothing is copied into a second large buffer.
                    for (unsigned i = 0; i < item.count && out; ++i)
                        out.write(reinterpret_cast<const char*>(item.data.get() + static_cast<std::size_t>(i) * item.size), static_cast<std::streamsize>(item.size));
                    out.flush();
                    ok = static_cast<bool>(out);
                }
            }
            if (ok) ok = MoveFileExA(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING) != 0;
            else DeleteFileA(temporary.c_str());
            name_out = name;
            bytes_out = header.size() + static_cast<std::uint64_t>(item.count) * item.size;
            return ok;
        }

        void writer_loop()
        {
            while (true)
            {
                WaitForSingleObject(wake, INFINITE);
                std::unique_ptr<job> item;
                {
                    std::lock_guard<std::mutex> lock(hand_mutex);
                    item = std::move(pending);
                }
                if (item)
                {
                    result r{};
                    r.ok = write_file(*item, r.name, r.bytes);
                    item.reset(); // the buffer is freed here, on the writer thread
                    {
                        std::lock_guard<std::mutex> lock(hand_mutex);
                        finished = r;
                    }
                    finished_ready = true;
                }
                if (writer_stop.load()) return;
            }
        }

        void report_done()
        {
            if (!finished_ready.exchange(false)) return;
            result r{};
            {
                std::lock_guard<std::mutex> lock(hand_mutex);
                r = finished;
            }
            if (r.ok) console::info("[Paris watch] written file=%s bytes=%llu\n", r.name.c_str(), static_cast<unsigned long long>(r.bytes));
            else console::error("[Paris watch] the file could not be written: %s\n", r.name.c_str());
            busy = false;
        }

        void pass()
        {
            report_done();
            if (!current) return;
            auto& item = *current;
            const auto t = now();
            if (t < item.next_due) return;
            const auto interval_ticks = static_cast<std::int64_t>(item.interval_ms) * qpc_hz / 1000;
            item.next_due += interval_ticks;
            if (item.next_due < t) item.next_due = t + interval_ticks; // fell behind: no burst of catch-up copies
            item.stamps[item.taken] = t;
            item.unreadable[item.taken] = copy_block(item.data.get() + item.taken * item.size, item.address, item.size);
            ++item.taken;
            if (item.taken < item.count) return;
            {
                std::lock_guard<std::mutex> lock(hand_mutex);
                pending = std::move(current);
            }
            current.reset();
            if (wake) SetEvent(wake);
        }
    }

    bool start(const std::uintptr_t address, const std::size_t size, const unsigned interval_ms, const unsigned count)
    {
        if (!enabled) { console::error("[Paris watch] not active: it needs -paris-watch and -paris-isolated-lab\n"); return false; }
        if (busy) { console::error("[Paris watch] a recording is still running or being written\n"); return false; }
        if (size < min_size || size > max_size || interval_ms < min_interval || interval_ms > max_interval ||
            count < min_count || count > max_count || static_cast<std::uint64_t>(size) * count > max_total ||
            !address || address + size < address)
        {
            console::error("[Paris watch] refused: size %zu (16..4194304), interval_ms %u (10..5000), count %u (2..600), size*count at most 268435456\n",
                size, interval_ms, count);
            return false;
        }
        auto item = std::make_unique<job>();
        item->data.reset(new (std::nothrow) std::uint8_t[size * count]);
        if (!item->data) { console::error("[Paris watch] cannot allocate %llu bytes\n", static_cast<unsigned long long>(size) * count); return false; }
        item->stamps.assign(count, 0);
        item->unreadable.assign(count, 0);
        item->address = address;
        item->size = size;
        item->interval_ms = interval_ms;
        item->count = count;
        item->next_due = now();
        current = std::move(item);
        busy = true;
        console::info("[Paris watch] begin address=%llX size=%zu interval_ms=%u count=%u\n", static_cast<unsigned long long>(address), size, interval_ms, count);
        return true;
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (game::environment::is_dedi()) return;
            if (!utils::flags::has_flag("paris-watch") || !utils::flags::has_flag("paris-isolated-lab")) return;
            LARGE_INTEGER frequency{};
            QueryPerformanceFrequency(&frequency);
            qpc_hz = frequency.QuadPart;
            if (qpc_hz <= 0) return;
            wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
            if (!wake) return;
            writer = std::thread(writer_loop);
            scheduler::loop(pass, scheduler::main);
            enabled = true;
            console::info("[Paris watch] ready\n");
        }
        void pre_destroy() override
        {
            if (!enabled) return;
            enabled = false;
            current.reset(); // an unfinished recording is dropped
            writer_stop = true;
            if (wake) SetEvent(wake);
            if (writer.joinable()) writer.join();
            if (wake) { CloseHandle(wake); wake = nullptr; }
        }
    };
}

REGISTER_COMPONENT(paris_watch::component)
