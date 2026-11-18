#pragma once
#include "game/game.hpp"
#include "dvars.hpp"
#include <utils/hook.hpp>

// The one list of the GPU, UI, sound-stream and texture-streaming hooks (docs/BOT-CLIENT.md). The dedicated server profile (client/component/dedicated.cpp)
// and the no-render bot client (paris_bot_client.cpp) both call paris_no_gpu::apply(); ops/Apply-SharedGpuHooksOverlay.ps1 removes the same sites from
// dedicated.cpp and makes it call this function, so a fix to a site is a fix to both. Sites that only a server wants (frame stub 1403471A0, CL_CheckForResend,
// game mode, hostname, heartbeat) stay in dedicated.cpp; sites only a client wants (the renderer calls inside the client frame) stay in paris_bot_client.cpp.
// <sites>
namespace paris_no_gpu
{
	inline void init_renderer_stub()
	{
		utils::hook::invoke<void>(0x140DF62C0);  // R_RegisterDvars
		utils::hook::invoke<void>(0x140DD7E50);  // R_RegisterCmds
		utils::hook::invoke<void>(0x1404B1320);  // RB_Tonemap_RegisterDvars
		static bool initialized = false;
		if (initialized) return;
		initialized = true;
		utils::hook::invoke<void>(0x140E06220);  // R_LoadGraphicsAssets
	}

	inline void apply()
	{
		using utils::hook::set;
		// registration of the renderer's dvars and commands still runs (scripts and configs read them); the graphics assets are not loaded
		dvars::override::register_bool("r_preloadShaders", false, game::DVAR_FLAG_READ);
		dvars::override::register_bool("r_loadForRenderer", false, game::DVAR_FLAG_READ);
		dvars::override::register_bool("intro", false, game::DVAR_FLAG_READ);
		utils::hook::jump(0x140341B60, init_renderer_stub, true);  // R_Init: no device, registrations only (as init_dedicated_server)
		set<uint8_t>(0x140E574E0, 0xC3);  // render thread
		set<uint8_t>(0x140D2EBB0, 0xC3);  // recommended settings check
		set<uint8_t>(0x140E08360, 0xC3);  // do not shut the renderer down
		set<uint8_t>(0x140D597C0, 0xC3);  // Voice_Init
		set(0x140CFDC40, 0xC3C033);       // sound stream reading
		set<uint8_t>(0x140A81D40, 0xC3);  // AlwaysLoaded
		set<uint8_t>(0x140A7DB10, 0xC3);  // DB_CreateGfxImageStreamInternal
		set<uint8_t>(0x140E01F00, 0xC3);  // Load_Texture
		set<uint8_t>(0x140A79AE0, 0xC3);  // transient loads
		set<uint8_t>(0x1403BB990, 0xC3);
		set<uint8_t>(0x140A78910, 0xC3);
		set<uint8_t>(0x14003B9A0, 0xC3);  // emblem
		set<uint8_t>(0x1405D0690, 0xC3);  // customization xmodels
		set<uint8_t>(0x140615090, 0xC3);  // LUI_CoD_Init
		set<uint8_t>(0x140348A90, 0xC3);  // CL_InitUI
		for (const unsigned long long a : { 0x140E06060ull, 0x140E05B80ull, 0x140DD2760ull, 0x140E05E20ull, 0x140E11270ull, 0x140DD3C50ull, 0x1400C1210ull, 0x1400C12B0ull,
			0x140E423A0ull, 0x140E04680ull, 0x140E00ED0ull, 0x140E00FC0ull, 0x140E011A0ull, 0x140E015C0ull, 0x140E01300ull, 0x1405F1EA0ull, 0x1400C1370ull, 0x140DD26E0ull,
			0x1405F0610ull, 0x1405F0580ull, 0x1405F0820ull, 0x1405F0790ull, 0x140DD42A0ull, 0x140DD42E0ull, 0x140DD4280ull, 0x140DD4230ull })
		{
			set(static_cast<size_t>(a), 0xC3C033);  // directx, image creation, renderer, shutdown
		}
		set<uint8_t>(0x1403B9E72, 0xEB);  // skip R_GetFrameIndex check in DB_LoadLevelXAssets
		set<uint8_t>(0x140DD4430, 0xC3);  // do not release buffer
		set<uint8_t>(0x140DD14C0, 0xC3);  // R_LoadWorld
		set<uint8_t>(0x140D02CB0, 0xC3);
		set<uint8_t>(0x140E7C970, 0xC3);  // recipe save threads
	}
}

// </sites>
