#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "command.hpp"
#include "console/console.hpp"
#include <utils/flags.hpp>
#include <utils/hook.hpp>
#include <DbgHelp.h>

// Crash dumps with the memory the crashing threads point to (lab clients and servers started with -paris-crash-memory; compiled with -Perf).
//
// The game's exception handler (src/common/exception/minidump.cpp of the pinned iw7-mod) writes its dump with MiniDumpWriteDump and a fixed
// type that holds the stacks and the module list but not the memory the pointers on them refer to, so a crash through a bad pointer cannot be traced to the
// code that wrote it. This component detours MiniDumpWriteDump and adds MiniDumpWithIndirectlyReferencedMemory (the memory around every pointer found on
// a stack: tens of megabytes, not the whole process) and MiniDumpWithDataSegs (the writable data of every module: the tables the game keeps its entities,
// scriptables and script variables in). The game's handler keeps the whole dump in memory to zip it, so a full-memory dump (several GB) is NOT asked for.
// Nothing changes for a process started without the flag.
namespace paris_crash_memory
{
    namespace
    {
        utils::hook::detour write_dump_hook;

        BOOL WINAPI write_dump_stub(HANDLE process, DWORD pid, HANDLE file, MINIDUMP_TYPE type, PMINIDUMP_EXCEPTION_INFORMATION exception,
            PMINIDUMP_USER_STREAM_INFORMATION user, PMINIDUMP_CALLBACK_INFORMATION callback)
        {
            const auto wide = static_cast<MINIDUMP_TYPE>(static_cast<int>(type) | MiniDumpWithIndirectlyReferencedMemory | MiniDumpWithDataSegs);
            if (write_dump_hook.invoke<BOOL>(process, pid, file, wide, exception, user, callback)) return TRUE;
            // the larger dump failed: the game's own type
            return write_dump_hook.invoke<BOOL>(process, pid, file, type, exception, user, callback);
        }
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (!utils::flags::has_flag("paris-crash-memory")) return;
            const auto module = LoadLibraryA("dbghelp.dll");
            const auto function = module ? reinterpret_cast<void*>(GetProcAddress(module, "MiniDumpWriteDump")) : nullptr;
            if (!function) { console::error("[Paris crash memory] MiniDumpWriteDump not found: dumps keep the game's type\n"); return; }
            write_dump_hook.create(function, write_dump_stub);
            // lab test: a write through a null pointer on the main thread, to read the dump this component asks for (only in an isolated lab)
            if (utils::flags::has_flag("paris-isolated-lab"))
                command::add("paris_crash_test", [] { *reinterpret_cast<volatile int*>(0x10) = 1; });
            console::info("[Paris crash memory] ready: dumps add indirectly referenced memory and module data\n");
        }
    };
}

REGISTER_COMPONENT(paris_crash_memory::component)
