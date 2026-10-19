#pragma once
#include <string>
namespace database { struct ScriptFile; }
namespace cutscene {
void observe_script(const std::string&, database::ScriptFile*);
bool key_event(int key, bool down);
}
namespace gsc { void redirect_code(const char*, const char*); }
