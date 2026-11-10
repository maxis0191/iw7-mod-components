#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "scheduler.hpp"
#include "console/console.hpp"
#include <utils/flags.hpp>
#include <utils/io.hpp>

// Client-side network update recorder for isolated lab clients (-paris-net with -paris-isolated-lab).
//
// While the client is in the active state, every pass of the engine's main pipeline looks at three values of the
// client game state (cg): latestSnapshotNum, latestSnapshotTime and predictedPlayerState.commandTime. Each time
// latestSnapshotNum changes it keeps the wall-clock gap since the previous change, the difference in snapshot number
// (above 1 means updates were skipped), the difference in server time, and how far the predicted time is ahead of the
// latest server time. It writes iw7-mod/paris-net/client.json every 5 seconds and when the client shuts down.
//
// Rules: the main thread only reads the three values and stores numbers into arrays sized at start. It never allocates,
// never formats and never touches a file. A writer thread formats and writes. It reads only array entries below a count
// that the main thread published under a lock, and the main thread only writes entries above that count. The console is
// used from the main thread only.
namespace paris_net
{
    namespace
    {
        constexpr std::size_t max_entries = 200000;
        constexpr std::int64_t write_seconds = 5;
        constexpr const char* output_path = "iw7-mod/paris-net/client.json";

        // The recorder reads these two fields of a partly known structure. The assertion ties them to the one asserted
        // field in front of them (game/structs.hpp), so an edit of the padding cannot move them silently.
        static_assert(offsetof(game::cg_s, latestSnapshotNum) == 492896);
        static_assert(offsetof(game::cg_s, latestSnapshotTime) == 492900);

        struct summary
        {
            double seconds{};
            std::uint64_t passes{}, updates{}, skipped{}, longest_run{}, discontinuities{};
            std::size_t gaps{}, steps{}, ahead{};
            int first_num{}, last_num{};
            bool truncated{};
            std::int64_t pid{};
        };

        // Main thread state.
        std::vector<std::int32_t> gaps_us, steps_ms, ahead_ms; // sized at start; a count says how much is filled
        std::size_t gaps_count{}, steps_count{}, ahead_count{};
        std::int64_t qpc_hz{}, last_pass{}, last_update{}, active_ticks{}, last_write{};
        std::uint64_t passes{}, updates{}, skipped{}, run{}, longest_run{}, discontinuities{};
        int first_num{}, last_num{}, last_time{};
        bool have_first{}, have_baseline{}, truncated{};
        bool announced{};

        // Hand-over to the writer thread.
        std::mutex hand_mutex;
        summary pending;
        bool pending_ready{};
        std::thread writer;
        HANDLE wake{};
        std::atomic<bool> writer_stop{false};
        std::atomic<bool> write_done{false};
        std::atomic<std::uint64_t> done_updates{0};
        std::atomic<std::int64_t> done_milliseconds{0};
        std::atomic<bool> done_ok{false};

        std::int64_t now()
        {
            LARGE_INTEGER value{};
            QueryPerformanceCounter(&value);
            return value.QuadPart;
        }

        // The reads below are guarded: nothing is dereferenced unless the object exists and the client is active.
        bool client_active()
        {
            const auto* ui = game::clientUIActives.get();
            return ui && ui[0].cgameInitialized && ui[0].connectionState == game::CA_ACTIVE;
        }

        template <typename Array>
        void keep(Array& array, std::size_t& count, const std::int64_t value)
        {
            if (count >= max_entries) { truncated = true; return; }
            array[count++] = static_cast<std::int32_t>(value);
        }

        summary snapshot()
        {
            summary s{};
            s.seconds = qpc_hz ? static_cast<double>(active_ticks) / static_cast<double>(qpc_hz) : 0.0;
            s.passes = passes;
            s.updates = updates;
            s.skipped = skipped;
            s.longest_run = longest_run;
            s.discontinuities = discontinuities;
            s.gaps = gaps_count;
            s.steps = steps_count;
            s.ahead = ahead_count;
            s.first_num = first_num;
            s.last_num = last_num;
            s.truncated = truncated;
            s.pid = GetCurrentProcessId();
            return s;
        }

        void append_array(std::string& out, const char* name, const std::vector<std::int32_t>& values, const std::size_t count)
        {
            out += '"';
            out += name;
            out += "\":[";
            for (std::size_t i = 0; i < count; ++i)
            {
                if (i) out += ',';
                out += std::to_string(values[i]);
            }
            out += ']';
        }

        bool write_document(const summary& s)
        {
            std::string out;
            out.reserve(1u << 20);
            char line[512]{};
            _snprintf_s(line, sizeof(line), _TRUNCATE,
                "{\"schema\":\"iw7.net-client/1\",\"pid\":%lld,\"seconds\":%.6f,\"passes\":%llu,\"updates\":%llu,\"skipped_updates\":%llu,"
                "\"longest_passes_without_update\":%llu,\"discontinuities\":%llu,\"first_snapshot_num\":%d,\"last_snapshot_num\":%d,\"truncated\":%s,"
                "\"source\":\"cg.latestSnapshotNum, cg.latestSnapshotTime, cg.predictedPlayerState.commandTime\",\n",
                static_cast<long long>(s.pid), s.seconds, static_cast<unsigned long long>(s.passes), static_cast<unsigned long long>(s.updates),
                static_cast<unsigned long long>(s.skipped), static_cast<unsigned long long>(s.longest_run),
                static_cast<unsigned long long>(s.discontinuities), s.first_num, s.last_num, s.truncated ? "true" : "false");
            out += line;
            append_array(out, "gaps_us", gaps_us, s.gaps);
            out += ",\n";
            append_array(out, "server_time_steps_ms", steps_ms, s.steps);
            out += ",\n";
            append_array(out, "ahead_ms", ahead_ms, s.ahead);
            out += "}\n";
            // A temporary file and a rename: a reader never sees half a document.
            const std::string temporary = std::string(output_path) + ".tmp";
            if (!utils::io::write_file(temporary, out)) return false;
            return MoveFileExA(temporary.c_str(), output_path, MOVEFILE_REPLACE_EXISTING) != 0;
        }

        void writer_loop()
        {
            while (true)
            {
                WaitForSingleObject(wake, INFINITE);
                if (writer_stop.load()) return;
                summary s{};
                {
                    std::lock_guard<std::mutex> lock(hand_mutex);
                    if (!pending_ready) continue;
                    s = pending;
                    pending_ready = false;
                }
                const bool ok = write_document(s);
                done_updates = s.updates;
                done_milliseconds = static_cast<std::int64_t>(s.seconds * 1000.0);
                done_ok = ok;
                write_done = true;
            }
        }

        void report_done()
        {
            if (!write_done.exchange(false)) return;
            if (done_ok.load())
                console::info("[Paris net] written updates=%llu seconds=%.3f\n", static_cast<unsigned long long>(done_updates.load()),
                    static_cast<double>(done_milliseconds.load()) / 1000.0);
            else
                console::error("[Paris net] the file could not be written\n");
        }

        void request_write()
        {
            {
                std::lock_guard<std::mutex> lock(hand_mutex);
                pending = snapshot();
                pending_ready = true;
            }
            if (wake) SetEvent(wake);
        }

        void leave_active()
        {
            // Another map or a reconnect restarts the numbering: the next observation is a new baseline, not an update.
            last_pass = 0;
            have_baseline = false;
            run = 0;
        }

        void pass()
        {
            report_done();
            if (!client_active()) { leave_active(); return; }
            const auto* state = game::cg.get();
            if (!state) { leave_active(); return; }
            const auto t = now();
            if (last_pass) active_ticks += t - last_pass;
            last_pass = t;
            ++passes;

            const int number = state->latestSnapshotNum;
            const int server_time = state->latestSnapshotTime;
            const int command_time = state->predictedPlayerState.commandTime;
            if (!have_first) { first_num = number; have_first = true; }
            if (!have_baseline)
            {
                have_baseline = true;
                last_num = number;
                last_time = server_time;
                last_update = t;
                run = 0;
            }
            else if (number == last_num)
            {
                ++run;
                if (run > longest_run) longest_run = run;
            }
            else
            {
                ++updates;
                const int difference = number - last_num;
                const int step = server_time - last_time;
                if (difference <= 0 || step < 0)
                {
                    // The numbering went backwards: a new match on the same connection. No gap or step is meaningful.
                    ++discontinuities;
                }
                else
                {
                    keep(gaps_us, gaps_count, (t - last_update) * 1000000 / qpc_hz);
                    keep(steps_ms, steps_count, step);
                    if (difference > 1) skipped += static_cast<std::uint64_t>(difference - 1);
                }
                keep(ahead_ms, ahead_count, static_cast<std::int64_t>(command_time) - server_time);
                last_num = number;
                last_time = server_time;
                last_update = t;
                run = 0;
            }

            if (t - last_write >= write_seconds * qpc_hz)
            {
                last_write = t;
                request_write();
            }
        }
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (game::environment::is_dedi()) return;
            if (!utils::flags::has_flag("paris-net") || !utils::flags::has_flag("paris-isolated-lab")) return;
            LARGE_INTEGER frequency{};
            QueryPerformanceFrequency(&frequency);
            qpc_hz = frequency.QuadPart;
            if (qpc_hz <= 0) return;
            // All memory is taken here, never while the game runs.
            gaps_us.assign(max_entries, 0);
            steps_ms.assign(max_entries, 0);
            ahead_ms.assign(max_entries, 0);
            wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
            if (!wake) return;
            last_write = now();
            writer = std::thread(writer_loop);
            scheduler::loop(pass, scheduler::main);
            announced = true;
            console::info("[Paris net] ready\n");
        }
        void pre_destroy() override
        {
            if (!announced) return;
            writer_stop = true;
            if (wake) SetEvent(wake);
            if (writer.joinable()) writer.join();
            if (passes)
            {
                const auto s = snapshot();
                const bool ok = write_document(s);
                console::info("[Paris net] written updates=%llu seconds=%.3f written=%d\n", static_cast<unsigned long long>(s.updates), s.seconds, static_cast<int>(ok));
            }
            if (wake) { CloseHandle(wake); wake = nullptr; }
        }
    };
}

REGISTER_COMPONENT(paris_net::component)
