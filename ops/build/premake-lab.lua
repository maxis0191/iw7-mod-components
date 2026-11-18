-- Lab client build (any profile with IsolatedLab or Debugger): the pinned premake5.lua builds Release with whole-program
-- optimization (/GL, linked with /LTCG): every build that changes one source then spends about 45 s in one serial link.
-- A lab client is a test client and is never deployed, so this wrapper takes /GL and /LTCG out and links incrementally.
-- Production profiles (the standard client, builds without IsolatedLab and Debugger) never use this file.
-- It stays next to premake5.lua so _MAIN_SCRIPT_DIR remains unchanged.
dofile("premake5.lua")

workspace "iw7-mod"
    filter "configurations:Release"
        removebuildoptions { "/GL" }
        removelinkoptions { "/LTCG" }
        removeflags { "NoIncrementalLink" }
        linkoptions { "/INCREMENTAL", "/OPT:NOREF", "/OPT:NOICF" }
    filter {}
