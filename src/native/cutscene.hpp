#pragma once
#include <string>
namespace game { struct ScriptFile; }
namespace cutscene { void observe_script(const std::string&, game::ScriptFile*); }
namespace gsc { void redirect_code(const char*, const char*); }
