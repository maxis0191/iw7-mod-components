#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "command.hpp"
#include "console/console.hpp"
#include "game/game.hpp"
#include "gsc/script_extension.hpp"
#include "scripting.hpp"
#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

// Total function replacement (a91, 20 Nov 2026).
//
// iw7-mod's replacefunc() (gsc/script_extension.cpp) is a check in the opcode fetch of the script VM: when the code position about to be executed equals the
// function's entry, the position is swapped for the replacement's. Measured on 20 Nov 2026 (docs/REPLACEFUNC.md of the server repository): calls that reach the
// entry through an opcode handler that does not go back to the fetch site (0x140C0D0A4) never meet the check, so the replacement is silently not used
// (zombie_util::_id_7FAA and _id_7FB1, a same-file call target). This builtin does not depend on how a call reaches the function: it writes a bytecode jump
// (OP_jump 0x76, int32 relative to the end of the instruction) over the first five bytes of the function's own code, so the first opcode ANY caller (direct,
// far, pointer, thread) executes is the jump into the replacement.
//
//   paris_replacefunc(what, with, "name")   patch `what`; the replacement's own prologue checks and creates its parameters as the original's did
//   paris_replace_reached("name")           the replacement says it ran (the audit's proof that a caller really got there)
//   paris_replace_count("name")             how often paris_replace_reached was called for the name, -1 when the name is not patched
//   console: paris_replace_audit            one line per patched function: patched, reached
//
// The bytes are scripts' own bytecode in memory, rebuilt at every map load: the table is cleared with the script shutdown. A function shorter than five
// bytes (the next function starts too soon) is refused and logged, never patched.
namespace paris_replace_total
{
    namespace
    {
        struct entry
        {
            std::string name;
            const char* from;
            const char* to;
            std::uint64_t reached;
            std::uint8_t original[5];
            bool patched;
        };
        std::vector<entry> entries;

        std::size_t function_size(const char* from)
        {
            // the distance to the nearest later function start (or the end marker of the file): script_function_table_sort is in registration order, not by position
            std::size_t best = 0;
            for (const auto& [file, functions] : scripting::script_function_table_sort)
            {
                for (const auto& function : functions)
                {
                    if (function.second > from)
                    {
                        const auto distance = static_cast<std::size_t>(function.second - from);
                        if (!best || distance < best) best = distance;
                    }
                }
            }
            return best;
        }

        entry* find(const std::string& name)
        {
            for (auto& e : entries) if (e.name == name) return &e;
            return nullptr;
        }

        void print_audit()
        {
            for (const auto& e : entries)
                console::info("[Paris replace] %s patched=%d reached=%llu\n", e.name.c_str(), e.patched ? 1 : 0, static_cast<unsigned long long>(e.reached));
            if (entries.empty()) console::info("[Paris replace] no function is patched\n");
        }

        class component final : public component_interface
        {
        public:
            void post_unpack() override
            {
                if (!game::environment::is_dedi()) return;
                gsc::function::add("paris_replacefunc", [](const gsc::function_args& args) -> scripting::script_value
                {
                    const auto what = args[0].get_raw();
                    const auto with = args[1].get_raw();
                    const auto name = args[2].as<std::string>();
                    if (what.type != game::VAR_FUNCTION || with.type != game::VAR_FUNCTION) throw std::runtime_error("paris_replacefunc: parameters 1 and 2 must be functions");
                    auto* from = const_cast<char*>(what.u.codePosValue);
                    const char* to = with.u.codePosValue;
                    if (find(name)) throw std::runtime_error("paris_replacefunc: name already used");
                    entry e{name, from, to, 0, {}, false};
                    const auto size = function_size(from);
                    if (size < 5)
                    {
                        console::info("[Paris replace] %s refused: the function is %zu bytes (a jump needs 5)\n", name.c_str(), size);
                        entries.push_back(e);
                        return scripting::script_value{0};
                    }
                    const auto delta = static_cast<std::int64_t>(to - (from + 5));
                    if (delta > INT32_MAX || delta < INT32_MIN) throw std::runtime_error("paris_replacefunc: the replacement is too far for a jump");
                    DWORD old{};
                    if (!VirtualProtect(from, 5, PAGE_EXECUTE_READWRITE, &old)) throw std::runtime_error("paris_replacefunc: the bytecode is not writable");
                    std::memcpy(e.original, from, 5);
                    from[0] = static_cast<char>(0x76);
                    const auto rel = static_cast<std::int32_t>(delta);
                    std::memcpy(from + 1, &rel, 4);
                    VirtualProtect(from, 5, old, &old);
                    e.patched = true;
                    entries.push_back(e);
                    return scripting::script_value{1};
                });
                gsc::function::add("paris_replace_reached", [](const gsc::function_args& args) -> scripting::script_value
                {
                    if (auto* e = find(args[0].as<std::string>())) ++e->reached;
                    return {};
                });
                gsc::function::add("paris_replace_count", [](const gsc::function_args& args) -> scripting::script_value
                {
                    const auto* e = find(args[0].as<std::string>());
                    return scripting::script_value{e ? static_cast<int>(std::min<std::uint64_t>(e->reached, 2000000000u)) : -1};
                });
                command::add("paris_replace_audit", [](const command::params&) { print_audit(); });
                scripting::on_shutdown([](bool free_scripts, bool)
                {
                    if (free_scripts) entries.clear();
                });
            }
        };
    }
}

REGISTER_COMPONENT(paris_replace_total::component)
