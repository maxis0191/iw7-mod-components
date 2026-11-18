#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "dvars.hpp"
#include "network.hpp"
#include "scheduler.hpp"
#include "console/console.hpp"
#include "party.hpp"
#include "paris_no_gpu.hpp"
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
			// the first run (botonly1) booted and then idled at 0% CPU with no join: the client frame waits on the render thread that the shared set removed.
			// botonly2 crashed here: sub_140E255F0+0xE reads the render command buffer ([148F730A0], null without a renderer); read from the crash dump (iw7_crash.py), callers R_EndFrame, 1403221D0, 1403B3C90, 1409BB520
			utils::hook::set(0x140E255F0, 0xC3C033);  // render command buffer alignment
			utils::hook::set<uint8_t>(0x140E267B0, 0xC3);  // R_EndFrame
			for (const unsigned long long r : { 0x140E27EE0ull, 0x140E27FE0ull, 0x140E26E30ull, 0x140E26520ull, 0x140E25660ull, 0x140E244A0ull })
				utils::hook::set<uint8_t>(static_cast<size_t>(r), 0xC3);  // R_SyncRenderThread, R_ToggleSmpFrame, R_IssueRenderCommandsBegin, and the draw submission calls of sub_140346F40
			utils::hook::call(0x1403428B1, sync_gpu_stub);  // R_SyncGpu: the pacing sleep at com_maxfps
			scheduler::once([]() { game::Com_GameMode_SetDesiredGameMode(game::GAME_MODE_CP); }, scheduler::pipeline::main);
			scheduler::loop(join, scheduler::pipeline::main, 1s);
		}
	};
}

REGISTER_COMPONENT(paris_bot_client::component)
