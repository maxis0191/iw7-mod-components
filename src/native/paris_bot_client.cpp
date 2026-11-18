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
#include <atomic>
#include <mutex>
#include <set>
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

		// Discovery loop in one run instead of one run per site: a null read (fault address below 64 KB) inside the game image is a renderer pointer the bot client has no renderer to fill.
		// The handler unwinds that one function (x64 unwind data), returns 0 from it and logs the site once; a site seen here is then given a proper stub or a zero block in a build.
		// More than 400 unwinds, a write, or a fault outside the image are not touched: the crash handler gets them.
		std::atomic<int> unwinds{};
		long __stdcall null_read_veh(EXCEPTION_POINTERS* info)
		{
			auto* rec = info->ExceptionRecord;
			if (rec->ExceptionCode != EXCEPTION_ACCESS_VIOLATION || rec->NumberParameters < 2 || rec->ExceptionInformation[0] != 0 || rec->ExceptionInformation[1] >= 0x10000) return EXCEPTION_CONTINUE_SEARCH;
			const auto rip = info->ContextRecord->Rip;
			if (rip < 0x140001000ull || rip >= 0x141435000ull || unwinds.load() > 400) return EXCEPTION_CONTINUE_SEARCH;
			DWORD64 base = 0;
			auto* entry = RtlLookupFunctionEntry(rip, &base, nullptr);
			if (!entry) return EXCEPTION_CONTINUE_SEARCH;
			PVOID handler_data = nullptr;
			DWORD64 frame = 0;
			RtlVirtualUnwind(UNW_FLAG_NHANDLER, base, rip, entry, info->ContextRecord, &handler_data, &frame, nullptr);
			info->ContextRecord->Rax = 0;
			static std::set<unsigned long long> seen;
			static std::mutex lock;
			{
				std::lock_guard<std::mutex> g(lock);
				if (seen.insert(rip).second) console::info("[Paris bot client] null read of %llx at rip %llx: function returned 0 (%d)
", static_cast<unsigned long long>(rec->ExceptionInformation[1]), static_cast<unsigned long long>(rip), unwinds.load() + 1);
			}
			unwinds++;
			return EXCEPTION_CONTINUE_EXECUTION;
		}


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
			AddVectoredExceptionHandler(1, null_read_veh);
			paris_no_gpu::zero_state_blocks = true;
			paris_no_gpu::apply();
			// the renderer's own registration still runs (as init_dedicated_server in the dedicated profile)
			utils::hook::set<uint8_t>(0x140E26490, 0xC3);   // R_BeginFrame
			utils::hook::set<uint8_t>(0x140E26EF0, 0xC3);   // R_IssueRenderCommandsEnd
			utils::hook::set<uint8_t>(0x140E56790, 0xC3);   // renderer call of the client frame (sub_1403471E0)
			// the first run (botonly1) booted and then idled at 0% CPU with no join: the client frame waits on the render thread that the shared set removed.
			// botonly2 crashed here: sub_140E255F0+0xE reads the render command buffer ([148F730A0], null without a renderer); read from the crash dump (iw7_crash.py), callers R_EndFrame, 1403221D0, 1403B3C90, 1409BB520
			// botonly6 (joined at 16.8 s, map loading, 1.36 GB working set) crashed in sub_140DD1B70+0x10 on the same renderer state pointer: now a zero block (paris_no_gpu::give_zero_state)
			utils::hook::set(0x140E255F0, 0xC3C033);  // render command buffer alignment
			utils::hook::set<uint8_t>(0x140E267B0, 0xC3);  // R_EndFrame
			// botonly3 joined (18.9 s, 1.36 GB working set) and crashed in the map load: sub_140DE2930+0x3A reads [148B2D7E0]+0x78, a renderer/image state that is null without a renderer; callers sub_140AA6480, sub_140AA6570, sub_140E350E0
			utils::hook::set(0x140DE2930, 0xC3C033);  // image slot bit clear
			// botonly4 idled; the rig's own stack capture (stacks-client.txt) read the wait: the main thread sits in DB_FindXAssetHeader (via DB_ReadRawFile) behind the db stream thread, which spins in
			// sub_140A81570 (called from sub_140A7ADF0+0x42E) until _DAT_145A69AD0 is set by the render side (the handshake with the render thread, never signalled without one)
			utils::hook::set<uint8_t>(0x140A81570, 0xC3);  // wait for the render side of the asset stream
			// botonly5: the stacks showed the db loader thread in sub_140A81640 (the same handshake on _DAT_145A69AD0, called from sub_140A84820), main thread behind it in DB_FindXAssetHeader
			utils::hook::set(0x140A81640, 0xC3C033);  // same wait, returns 0
			for (const unsigned long long r : { 0x140E27EE0ull, 0x140E27FE0ull, 0x140E26E30ull, 0x140E26520ull, 0x140E25660ull, 0x140E244A0ull })
				utils::hook::set<uint8_t>(static_cast<size_t>(r), 0xC3);  // R_SyncRenderThread, R_ToggleSmpFrame, R_IssueRenderCommandsBegin, and the draw submission calls of sub_140346F40
			utils::hook::call(0x1403428B1, sync_gpu_stub);  // R_SyncGpu: the pacing sleep at com_maxfps
			scheduler::once([]() { game::Com_GameMode_SetDesiredGameMode(game::GAME_MODE_CP); }, scheduler::pipeline::main);
			scheduler::loop(join, scheduler::pipeline::main, 1s);
		}
	};
}

REGISTER_COMPONENT(paris_bot_client::component)
