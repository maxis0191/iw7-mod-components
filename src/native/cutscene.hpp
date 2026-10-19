#pragma once
#include <string>
namespace database { struct ScriptFile; }
namespace cutscene { void observe_script(const std::string&, database::ScriptFile*); }
namespace gsc { void redirect_code(const char*, const char*); }
