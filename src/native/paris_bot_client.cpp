#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "dvars.hpp"
#include "network.hpp"
#include "scheduler.hpp"
#include "console/console.hpp"
#include "party.hpp"
#include <utils/flags.hpp>
#include <utils/hook.hpp>
#include <thread>
#include <chrono>

// -paris-bot-client (docs/BOT-CLIENT.md): a real network client with no renderer, no sound banks, no UI and no texture streaming. It connects, parses snapshots and sends
// usercmds through the engine's own client code (CL_CheckForResend, the snapshot parse and CL_WritePacket stay live); only the GPU work, the UI and the asset
// streaming that feeds the GPU are removed. The GPU, UI and streaming hooks are the dedicated server's (client/component/dedicated.cpp), which every dedicated server
// runs; they are listed once here (paris_no_gpu::apply) and the dedicated profile is to call the same function (docs/BOT-CLIENT.md, "One list").
// The client frame (sub_1403471E0, called by sub_1403471A0) mixes client work and renderer calls: the dedicated profile stubs 1403471A0 whole, this one stubs only
// the renderer calls inside the frame (R_BeginFrame, R_IssueRenderCommandsEnd and 140E56790) and keeps the rest.
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

namespace paris_bot_client
{
	namespace
	{
		bool joined{};

		void sync_gpu_stub(void* a1)
		{
			utils::hook::invoke<void>(0x140E08AE0, a1);  // R_SyncGpu, as the dedicated server's pacing
			const auto* fps = game::Dvar_FindVar("com_maxfps");
			const int cap = fps && fps->current.integer > 0 ? fps->current.integer : 20;
			const auto frame_ms = 1000 / cap;
			const auto msec = (*game::com_frameTime + frame_ms) - game::Sys_Milliseconds();
			if (msec > 0 && msec < 1000) std::this_thread::sleep_for(std::chrono::milliseconds(msec));
		}

		int lab_port()
		{
			const auto* port = game::Dvar_FindVar("paris_lab_server_port");
			if (!port) return 0;
			int value = 0;
			if (port->type == game::DVAR_TYPE_STRING) value = std::atoi(port->current.string);
			else if (port->type == game::DVAR_TYPE_INT) value = port->current.integer;
			return value >= 27100 && value <= 27999 ? value : 0;
		}

		void join()
		{
			if (joined) return;
			if (game::Com_GameMode_GetActiveGameMode() != game::GAME_MODE_CP)
			{
				game::Com_GameMode_SetDesiredGameMode(game::GAME_MODE_CP);
				return;
			}
			if (game::Live_SyncOnlineDataFlags(0) != 0 || !lab_port()) return;
			game::netadr_s target{};
			target.type = game::NA_IP; target.ip[0] = 127; target.ip[3] = 1;
			target.port = htons(static_cast<unsigned short>(lab_port()));
			joined = true;
			console::info("[Paris bot client] Loopback join to UDP %d.\n", lab_port());
			party::connect(target);
		}
	}

	class component final : public component_interface
	{
	public:
		void post_unpack() override
		{
			if (!utils::flags::has_flag("paris-bot-client") || !utils::flags::has_flag("paris-isolated-lab")) return;
			console::info("[Paris bot client] no renderer, no UI, no texture streaming.\n");
			paris_no_gpu::apply();
			// the renderer's own registration still runs (as init_dedicated_server in the dedicated profile)
			utils::hook::set<uint8_t>(0x140E26490, 0xC3);   // R_BeginFrame
			utils::hook::set<uint8_t>(0x140E26EF0, 0xC3);   // R_IssueRenderCommandsEnd
			utils::hook::set<uint8_t>(0x140E56790, 0xC3);   // renderer call of the client frame (sub_1403471E0)
			utils::hook::call(0x1403428B1, sync_gpu_stub);  // R_SyncGpu: the pacing sleep at com_maxfps
			scheduler::once([]() { game::Com_GameMode_SetDesiredGameMode(game::GAME_MODE_CP); }, scheduler::pipeline::main);
			scheduler::loop(join, scheduler::pipeline::main, 1s);
		}
	};
}

REGISTER_COMPONENT(paris_bot_client::component)
