#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "command.hpp"
#include "console/console.hpp"
#include "game/game.hpp"
#include "gsc/script_extension.hpp"
#include "scheduler.hpp"
#include "scripting.hpp"
#include "paris_log_stream.hpp"
#include <utils/flags.hpp>
#include <algorithm>
#include <unordered_map>
#include <vector>
#include <intrin.h>

// Weapon-give recorder for dedicated servers: -paris-weapon-log (a80, 17 Nov 2026).
//
// Why: in an owner playtest the client loaded 35 weapon zones in a minute and no log said which script gave those weapons.
// Every call of the script builtin methods giveweapon, takeweapon, switchtoweapon and switchtoweaponimmediate writes one
// flight-recorder line to the server's game log (iw7-mod/logs/games_mp.log, the file the slow-frame watchdog of paris_sperf.cpp
// and the script recorder write to, through the buffered handle of paris_log_stream; ops/play/flight_report.py reads it):
//
//   [FR] t=<level time> weapon_give fn=<giveweapon|takeweapon|switchtoweapon|switchtoweaponimmediate> ent=<entity number> w=<weapon name>
//        frame=<server frame> caller=<file::function> chain=<outer callers, innermost first, joined by '<'> verified=<1|0>
//
// The hook (the method table entry, see below) does one thing: it reads the call and appends a fixed-size record to a ring of 4,096
// records, then calls the stock handler. Names are made later, in the scheduler's server pipeline once a frame (the same thread, so the
// script function table cannot change under it), and the line is appended to the log handle.
//
// How the caller is read: at the call, scr_function_stack->pos is the code position inside the calling function just after the call
// opcode (gsc::get_function_id reads the id of the called function from the two bytes before it) and scr_VmPub->function_frame_start[k].fs.pos
// are the positions of the outer frames of the same thread (as paris_sperf.cpp reads them). The position is mapped to "file::function" through
// the function table iw7-mod keeps (scripting::script_function_table_sort). A position that is in no function is written as 0x<address>.
// verified=1 means the two bytes before the position equal the id of the method that is running: the call came from script bytecode. A call from native code
// (the owner's "give" command, scripting::call) leaves the position of whatever script ran before: it is written verified=0 and its caller is not trusted.
// The chain ends at the root of the thread: a thread that started after a wait or a notify has no outer frames.
//
// The engine fills gsc::meth_table at game start, after this component's post_unpack: the entries are taken over by a check in the frame loop
// (a refill of the table by the engine is taken over again). The handler addresses are written to the log when they are taken.
namespace paris_weapon_log
{
    namespace
    {
        constexpr std::size_t ring_size = 4096;
        constexpr std::size_t max_chain = 8; // the calling function and seven outer ones
        constexpr std::size_t weapon_chars = 128; // the longest names (a pack-a-punched weapon with its attachments and camo) are about 100

        struct method_slot { const char* name; unsigned short id; };
        constexpr method_slot slots[4] = {
            {"giveweapon", 0x817D}, {"takeweapon", 0x83B8}, {"switchtoweapon", 0x83B5}, {"switchtoweaponimmediate", 0x83B6},
        };

        struct record
        {
            int level_time;
            std::uint64_t frame;
            std::uintptr_t pos[max_chain];
            unsigned short entity;
            unsigned char which, depth, arg_type, verified;
            char weapon[weapon_chars];
        };

        record ring[ring_size];
        std::size_t head{}, tail{};                 // server thread only
        std::atomic<std::uint64_t> frame{0}, recorded{0}, lost{0}, foreign{0}, written{0}, fallback{0};
        std::atomic<std::int64_t> hook_ns{0}, drain_ns{0};
        std::uint64_t stats_recorded{}, stats_lost{}, stats_foreign{}, stats_frame{};
        std::atomic<DWORD> server_thread{0};
        gsc::builtin_method original[4]{};
        bool measure{};
        std::int64_t qpc_hz{};

        struct function_row { std::uintptr_t start; const std::string* file; const std::string* name; };
        std::vector<function_row> rows;
        std::size_t rows_files = ~static_cast<std::size_t>(0);
        bool rows_dirty = true;
        std::unordered_map<std::uintptr_t, std::string> names;

        std::int64_t now()
        {
            LARGE_INTEGER value{};
            QueryPerformanceCounter(&value);
            return value.QuadPart;
        }

        // Plain reads of the VM state of the calling thread; a frame pointer outside the frame array is no chain (never a crash).
        unsigned read_vm(std::uintptr_t* out)
        {
            __try
            {
                auto* pub = game::scr_VmPub.get();
                const auto* first = &pub->function_frame_start[0];
                const auto* last = &pub->function_frame_start[31];
                const auto* top = pub->function_frame;
                if (top < first || top > last) return 0;
                const auto depth = static_cast<std::size_t>(top - first);
                const char* running = game::scr_function_stack->pos;
                if (!running) return 0;
                out[0] = reinterpret_cast<std::uintptr_t>(running);
                unsigned count = 1;
                for (std::size_t k = depth; k > 1 && count < max_chain; --k)
                    out[count++] = reinterpret_cast<std::uintptr_t>(first[k - 1].fs.pos);
                return count;
            }
            __except (EXCEPTION_EXECUTE_HANDLER)
            {
                return 0;
            }
        }

        bool position_names_method(const std::uintptr_t position, const unsigned short id)
        {
            __try { return *reinterpret_cast<const std::uint16_t*>(position - 2) == id; }
            __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
        }

        void record_call(const int which, const game::scr_entref_t ref)
        {
            const auto begin = measure ? now() : 0;
            const auto thread = GetCurrentThreadId();
            auto expected = DWORD{0};
            server_thread.compare_exchange_strong(expected, thread);
            if (server_thread.load(std::memory_order_relaxed) != thread) { ++foreign; return; }
            if (head - tail >= ring_size) { ++lost; return; }
            auto& r = ring[head % ring_size];
            r.level_time = *game::gameTime;
            r.frame = frame.load(std::memory_order_relaxed);
            r.entity = ref.entnum;
            r.which = static_cast<unsigned char>(which);
            r.depth = static_cast<unsigned char>(read_vm(r.pos));
            r.verified = r.depth && position_names_method(r.pos[0], slots[which].id) ? 1 : 0;
            r.arg_type = 0xFF;
            r.weapon[0] = 0;
            auto* pub = game::scr_VmPub.get();
            if (pub->outparamcount > 0)
            {
                const auto& value = pub->top[0];
                r.arg_type = static_cast<unsigned char>(value.type);
                if (value.type == game::VAR_STRING || value.type == game::VAR_ISTRING)
                {
                    const auto* text = game::SL_ConvertToString(static_cast<game::scr_string_t>(value.u.stringValue));
                    if (text) { strncpy_s(r.weapon, sizeof(r.weapon), text, _TRUNCATE); }
                }
            }
            ++head;
            ++recorded;
            if (measure) hook_ns += (now() - begin) * 1000000000ll / qpc_hz;
        }

        template <int Which> void wrapper(game::scr_entref_t ref)
        {
            record_call(Which, ref);
            original[Which](ref);
        }
        const gsc::builtin_method wrappers[4] = {wrapper<0>, wrapper<1>, wrapper<2>, wrapper<3>};

        void rebuild_rows()
        {
            rows.clear();
            for (const auto& [file, functions] : scripting::script_function_table_sort)
                for (const auto& entry : functions)
                    rows.push_back({reinterpret_cast<std::uintptr_t>(entry.second), &file, &entry.first});
            std::sort(rows.begin(), rows.end(), [](const function_row& a, const function_row& b) { return a.start < b.start; });
            rows_files = scripting::script_function_table_sort.size();
            rows_dirty = false;
        }

        std::string resolve(const std::uintptr_t position, bool& unresolved)
        {
            unresolved = false;
            const auto cached = names.find(position);
            if (cached != names.end()) return cached->second;
            if (rows_dirty || rows_files != scripting::script_function_table_sort.size()) rebuild_rows();
            std::string name;
            const auto at = std::upper_bound(rows.begin(), rows.end(), position, [](const std::uintptr_t value, const function_row& row) { return value < row.start; });
            if (at != rows.begin() && *(at - 1)->name != "__end__")
            {
                std::string file = *(at - 1)->file;
                const auto slash = file.find_last_of("/\\");
                if (slash != std::string::npos) file = file.substr(slash + 1);
                name = file + "::" + *(at - 1)->name;
            }
            else
            {
                char text[32]{};
                _snprintf_s(text, sizeof(text), _TRUNCATE, "0x%llx", static_cast<unsigned long long>(position));
                unresolved = true;
                return text; // not cached: the table may grow
            }
            if (names.size() < 20000) names.emplace(position, name);
            return name;
        }

        void log_line(const std::string& text)
        {
            if (paris_log_stream::instance().append("iw7-mod/logs/games_mp.log", text)) { ++written; return; }
            ++fallback;
            console::info("%s", text.c_str());
        }

        void take_over()
        {
            // The engine fills the table at game start and may fill it again; each new stock handler is taken and logged once.
            for (int i = 0; i < 4; ++i)
            {
                auto& slot = gsc::meth_table[slots[i].id - 0x8000];
                if (!slot || slot == wrappers[i]) continue;
                original[i] = slot;
                slot = wrappers[i];
                char text[256]{};
                _snprintf_s(text, sizeof(text), _TRUNCATE, "[FR] t=%d weapon_log_handler fn=%s id=0x%x handler=0x%llx\n",
                    *game::gameTime, slots[i].name, static_cast<unsigned>(slots[i].id), static_cast<unsigned long long>(reinterpret_cast<std::uintptr_t>(original[i])));
                log_line(text);
            }
        }

        void flush_ring()
        {
            if (head == tail) return;
            std::string text;
            while (tail != head)
            {
                const auto& r = ring[tail % ring_size];
                std::string caller, chain;
                bool unresolved = false;
                if (!r.depth) caller = "none";
                for (unsigned i = 0; i < r.depth; ++i)
                {
                    const auto name = resolve(r.pos[i], unresolved);
                    if (!i) caller = name;
                    else { if (i > 1) chain += '<'; chain += name; }
                }
                char line[1024]{};
                const char* weapon = r.weapon[0] ? r.weapon : "none";
                char typed[24]{};
                if (!r.weapon[0] && r.arg_type != 0xFF) { _snprintf_s(typed, sizeof(typed), _TRUNCATE, "type%u", static_cast<unsigned>(r.arg_type)); weapon = typed; }
                _snprintf_s(line, sizeof(line), _TRUNCATE, "[FR] t=%d weapon_give fn=%s ent=%u w=%s frame=%llu caller=%s chain=%s verified=%u\n",
                    r.level_time, slots[r.which].name, static_cast<unsigned>(r.entity), weapon, static_cast<unsigned long long>(r.frame),
                    caller.c_str(), chain.empty() ? "-" : chain.c_str(), static_cast<unsigned>(r.verified));
                text += line;
                ++tail;
            }
            log_line(text);
        }

        // A stats row when something was lost or came from another thread (so a reader never takes a log with gaps for a complete one), and about once a minute.
        void stats_row(const bool force = false)
        {
            const auto f = frame.load();
            const bool bad = lost.load() != stats_lost || foreign.load() != stats_foreign;
            const bool changed = recorded.load() != stats_recorded;
            if (!bad && !(changed && (force || f - stats_frame >= 1200))) return;
            stats_recorded = recorded.load(); stats_lost = lost.load(); stats_foreign = foreign.load(); stats_frame = f;
            char text[320]{};
            _snprintf_s(text, sizeof(text), _TRUNCATE, "[FR] t=%d weapon_log_stats recorded=%llu lost=%llu foreign=%llu written=%llu hook_ns=%lld drain_ns=%lld\n",
                *game::gameTime, static_cast<unsigned long long>(stats_recorded), static_cast<unsigned long long>(stats_lost), static_cast<unsigned long long>(stats_foreign),
                static_cast<unsigned long long>(written.load()), static_cast<long long>(hook_ns.load()), static_cast<long long>(drain_ns.load()));
            log_line(text);
        }

        void drain()
        {
            ++frame;
            take_over();
            const auto begin = measure && head != tail ? now() : 0;
            flush_ring();
            if (begin) drain_ns += (now() - begin) * 1000000000ll / qpc_hz;
            stats_row();
        }

        void print_stats()
        {
            const auto n = recorded.load();
            console::info("[Paris weapon log] recorded=%llu lost=%llu foreign_thread=%llu lines_written=%llu console_fallback=%llu hook_ns_total=%lld hook_ns_per_call=%.1f drain_ns_total=%lld measure=%d\n",
                static_cast<unsigned long long>(n), static_cast<unsigned long long>(lost.load()), static_cast<unsigned long long>(foreign.load()),
                static_cast<unsigned long long>(written.load()), static_cast<unsigned long long>(fallback.load()),
                static_cast<long long>(hook_ns.load()), n ? static_cast<double>(hook_ns.load()) / static_cast<double>(n) : 0.0, static_cast<long long>(drain_ns.load()), measure ? 1 : 0);
        }
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (!game::environment::is_dedi() || !utils::flags::has_flag("paris-weapon-log")) return;
            LARGE_INTEGER frequency{};
            QueryPerformanceFrequency(&frequency);
            qpc_hz = frequency.QuadPart;
            measure = utils::flags::has_flag("paris-weapon-log-measure");
            scheduler::loop(drain, scheduler::server);
            // A script shutdown frees the function table: positions named before it stay valid text, the table is rebuilt for the next game.
            scripting::on_shutdown([](bool free_scripts, bool)
            {
                if (!free_scripts) return;
                flush_ring(); // what is still in the ring is written now; positions that are not cached already are written as addresses
                stats_row(true);
                rows_dirty = true;
                rows.clear();
                names.clear();
            });
            // The console runs on another thread than the server's: the ring is flushed and a stats row written by the server thread (the next frame), then the counters are printed.
            command::add("paris_weapon_log_stats", [](const command::params&)
            {
                scheduler::once([] { flush_ring(); stats_row(true); print_stats(); }, scheduler::server);
            });
            console::info("[Paris weapon log] ready: giveweapon, takeweapon, switchtoweapon and switchtoweaponimmediate go to the [FR] lines of the game log%s\n", measure ? " (cost measurement on)" : "");
        }

        void pre_destroy() override
        {
            if (server_thread.load()) print_stats();
        }
    };
}

REGISTER_COMPONENT(paris_weapon_log::component)
