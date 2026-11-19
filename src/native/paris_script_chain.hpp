#pragma once
#include <string>

// The script call chain of the thread that is running a builtin right now, as "file::function<outer<outer" (innermost first, at most 8). For a diagnostic line written
// by native code that is reached from a script builtin (a89: the navigator release on a destroyed agent, reached from clearpath()). Server thread only; names come from the function
// table of paris_weapon_log.cpp. An empty string when the VM state is not readable.
namespace paris_weapon_log
{
    std::string script_chain();
}
