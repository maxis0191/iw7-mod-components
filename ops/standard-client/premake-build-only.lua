-- Build-only source adapter: never inherit an upstream deployment destination.
-- This wrapper stays next to premake5.lua so _MAIN_SCRIPT_DIR remains unchanged.
local source_getenv = os.getenv
os.getenv = function(name)
    if name == "COMPUTERNAME" or name == "AURORAIW7_GAME_PATH" then
        return nil
    end
    return source_getenv(name)
end
_OPTIONS["copy-to"] = nil
dofile("premake5.lua")
