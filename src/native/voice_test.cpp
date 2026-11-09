#include <std_include.hpp>
#include "loader/component_loader.hpp"

#include "game/game.hpp"

#include "command.hpp"
#include "console/console.hpp"
#include "scheduler.hpp"

#include <utils/hook.hpp>
#include <utils/string.hpp>

#include <algorithm>
#include <bit>
#include <charconv>
#include <share.h>

// Private voice certification probe. It is never part of an upstream branch: lab builds copy it
// into src/client/component next to voice.cpp. It does nothing unless the process is started
// with -voicetest <absolute dir>.
//
// Client: a virtual microphone feeds known PCM into the native capture callback, so gain, VAD,
// Speex, batching and voice.cpp all run unmodified, and every decoded buffer the engine queues
// for playback is recorded per talker. Dedicated server: command channel and snapshots only.
// Every engine address is compared with the retail code bytes before anything is installed.
// See docs/VOICE-CERTIFY.md, section "Test component".

namespace voice_test
{
	namespace
	{
		constexpr auto max_talkers = 18;
		constexpr auto report_interval = 500; // ms between recv/encoded events of one stream
		constexpr size_t max_command_read = 0x10000;

		enum role : std::uint8_t
		{
			role_client = 1,
			role_server = 2,
			role_both = role_client | role_server,
		};

		// Engine code
		constexpr std::uintptr_t capture_callback_thunk = 0x140B79CD0; // jmp voice_capture_pcm; the capture device callback
		constexpr std::uintptr_t voice_capture_pcm = 0x140B79D30;
		constexpr std::uintptr_t encoded_queue_call = 0x140B79F13; // the only call of voice_encoded_queue
		constexpr std::uintptr_t voice_encoded_queue = 0x14037D960;
		constexpr std::uintptr_t pcm_enqueue_call = 0x140D5972A; // the only call of the playback enqueue (Voice_IncomingVoiceData)
		constexpr std::uintptr_t pcm_enqueue = 0x140B796D0;
		constexpr std::uintptr_t voice_mute = 0x140D59AC0; // also called by the native mute toggle 0x14037C8A0
		constexpr std::uintptr_t voice_unmute = 0x140D59FE0;
		constexpr std::uintptr_t voice_get_session = 0x140D32740;
		constexpr std::uintptr_t voice_get_local_talker = 0x140D32920;
		constexpr std::uintptr_t controller_index = 0x140347690;
		constexpr std::uintptr_t speex_frame_size = 0x140B79440;
		constexpr std::uintptr_t lobby_is_running = 0x1409C3EC0;
		constexpr std::uintptr_t lobby_get_session = 0x1409C3E30;
		constexpr std::uintptr_t party_is_in_game = 0x1409CD3F0;

		// Engine data
		auto* const playback_streams = reinterpret_cast<void* const*>(0x1477A01C0); // [talker], created by Voice_Init
		auto* const voice_rate = reinterpret_cast<const int*>(0x141BB2CA0); // capture and playback sample rate
		auto* const voice_channels = reinterpret_cast<const int*>(0x141BB2CA8);
		auto* const voice_initialized = reinterpret_cast<const int*>(0x1477A012C);
		constexpr std::uintptr_t game_session = 0x146B4E080;
		constexpr std::uintptr_t party_session = 0x146B50B30;

		struct code_check
		{
			const char* name;
			std::uintptr_t address;
			std::vector<std::uint8_t> bytes;
			role roles;
		};

		// Expected bytes copied from the unpacked retail code (file offset = address - 0x140001000).
		// ops/voice-certify/check_voice_test_bytes.py re-checks this table against the dump.
		const std::vector<code_check> code_checks =
		{
			// the capture device callback is this jmp (stored by 0x140B79D00)
			{"capture callback thunk", 0x140B79CD0, {0xE9, 0x5B, 0x00, 0x00, 0x00}, role_client},
			// capture block: bytes per sample +0x10 must be 2, sample count +0xC
			{"voice_capture_pcm", 0x140B79D30, {0x40, 0x57, 0x41, 0x57, 0xB8, 0x48, 0x20, 0x00, 0x00, 0xE8, 0xD2, 0x03, 0x74, 0x00,
				0x48, 0x2B, 0xE0, 0x48, 0x8B, 0x05, 0xE8, 0x77, 0x06, 0x01, 0x48, 0x33, 0xC4, 0x48, 0x89, 0x84, 0x24, 0x20, 0x20, 0x00,
				0x00, 0x0F, 0x57, 0xC9, 0x45, 0x33, 0xFF, 0xF3, 0x0F, 0x11, 0x0D, 0xC7, 0x63, 0xC2, 0x06, 0x48, 0x8B, 0xF9, 0x83, 0x79,
				0x10, 0x02, 0x75, 0x7F, 0x8B, 0x41, 0x0C, 0x85, 0xC0, 0x7E}, role_client},
			// frame size call, consumed +0x20 = 0, byte count +0x8 > 0
			{"voice_capture_pcm block", 0x140B79E1D, {0xE8, 0x1E, 0xF6, 0xFF, 0xFF, 0x44, 0x89, 0x7F, 0x20, 0x8B, 0xE8, 0x45, 0x8B,
				0xF7, 0x85, 0xC0, 0x7E, 0x06, 0x44, 0x39, 0x7F, 0x08, 0x7F, 0x07, 0x33, 0xC0, 0xE9, 0x4C, 0x01, 0x00, 0x00}, role_client},
			{"encoded queue call", 0x140B79F13, {0xE8, 0x48, 0x3A, 0x80, 0xFF}, role_client},
			{"voice_encoded_queue", 0x14037D960, {0x40, 0x53, 0x48, 0x83, 0xEC, 0x20, 0x48, 0x63, 0xD9, 0x85, 0xC9, 0x0F, 0x8E, 0x82,
				0x00, 0x00, 0x00}, role_client},
			// Voice_IncomingVoiceData: the talker (2nd argument) indexes the stream table at image base + 0x77A01C0
			{"incoming talker index", 0x140D59648, {0x48, 0x63, 0xFA, 0x4C, 0x8D, 0x25, 0xAE, 0x69, 0x2A, 0xFF, 0x41, 0x8B, 0xE9, 0x4D,
				0x8B, 0xF8, 0x4C, 0x8B, 0xF7, 0x49, 0x83, 0xBC, 0xFC, 0xC0, 0x01, 0x7A, 0x07, 0x00}, role_client},
			// enqueue(streams[talker], decoded pcm, decoded byte count)
			{"incoming playback enqueue", 0x140D5971A, {0x4B, 0x8B, 0x8C, 0xF4, 0xC0, 0x01, 0x7A, 0x07, 0x48, 0x8D, 0x54, 0x24, 0x20,
				0x44, 0x8B, 0xC0, 0xE8, 0xA1, 0xFF, 0xE1, 0xFF}, role_client},
			{"playback enqueue thunk", 0x140B796D0, {0xE9, 0x8B, 0x04, 0x00, 0x00}, role_client},
			// users[i].muted = session + 0x60 + i * 0x38 + 0x30
			{"voice mute", 0x140D59AC0, {0x48, 0x63, 0xC2, 0x48, 0x6B, 0xD0, 0x38, 0xC6, 0x84, 0x0A, 0x90, 0x00, 0x00, 0x00, 0x01, 0xC3}, role_client},
			{"voice unmute", 0x140D59FE0, {0x48, 0x63, 0xC2, 0x48, 0x6B, 0xD0, 0x38, 0xC6, 0x84, 0x0A, 0x90, 0x00, 0x00, 0x00, 0x00, 0xC3}, role_client},
			// party in game ? g_partyData session : gameSession 0x146B4E080
			{"voice session", 0x140D32740, {0x48, 0x83, 0xEC, 0x28, 0x48, 0x8D, 0x0D, 0x55, 0x26, 0x52, 0x04, 0xE8, 0xA0, 0xAC, 0xC9,
				0xFF, 0x85, 0xC0, 0x48, 0x8B, 0x05, 0x47, 0x26, 0x52, 0x04, 0x75, 0x07, 0x48, 0x8D, 0x05, 0x1E, 0xB9, 0xE1, 0x05, 0x48,
				0x83, 0xC4, 0x28, 0xC3}, role_client},
			// Session_Init names 0x146B50B30 "partySession"
			{"party session name", 0x140C72AFC, {0x48, 0x8D, 0x05, 0xBD, 0x34, 0x8A, 0x00, 0x48, 0x89, 0x05, 0x26, 0xE0, 0xED, 0x05}, role_client},
			// the scoreboard mute (LUI 0x140500BC0): front end ? none : lobby running ? lobby session
			// : party in game ? party session : game session, then the toggle 0x14037C8A0
			{"scoreboard mute session", 0x140500BD2, {0xE8, 0xC9, 0xDF, 0x0A, 0x00, 0x33, 0xF6, 0x84, 0xC0, 0x74, 0x04, 0x8B, 0xDE,
				0xEB, 0x36, 0xE8, 0xDA, 0x32, 0x4C, 0x00, 0x84, 0xC0, 0x74, 0x07, 0xE8, 0x41, 0x32, 0x4C, 0x00, 0xEB, 0x1E, 0x48, 0x8D,
				0x0D, 0xA8, 0x41, 0xD5, 0x04, 0xE8, 0xF3, 0xC7, 0x4C, 0x00, 0x85, 0xC0, 0x74, 0x09, 0x48, 0x8B, 0x1D, 0x98, 0x41, 0xD5,
				0x04, 0xEB, 0x08, 0xE8, 0x31, 0x1C, 0x4B, 0x00, 0x48, 0x8B, 0xD8}, role_client},
			{"lobby running", 0x1409C3EC0, {0x48, 0x83, 0xEC, 0x28, 0x83, 0x3D, 0xE5, 0xB2, 0x88, 0x04, 0x00, 0x74, 0x17, 0x48, 0x8D,
				0x0D, 0xCC, 0x85, 0x88, 0x04, 0xE8, 0x17, 0x9E, 0x00, 0x00, 0x85, 0xC0, 0x74, 0x07, 0xB0, 0x01, 0x48, 0x83, 0xC4, 0x28,
				0xC3}, role_client},
			{"lobby session", 0x1409C3E30, {0x48, 0x8B, 0x05, 0x69, 0x86, 0x88, 0x04, 0xC3}, role_client},
			// g_partyData 0x145254DA0: inParty +0x2D10 and +0x2D14
			{"party in game", 0x1409CD3F0, {0x83, 0xB9, 0x14, 0x2D, 0x00, 0x00, 0x00, 0x74, 0x0F, 0x83, 0xB9, 0x10, 0x2D, 0x00, 0x00,
				0x00, 0x74, 0x06, 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3, 0x33, 0xC0, 0xC3}, role_client},
			{"voice local talker", 0x140D32920, {0x48, 0x63, 0xC1, 0x4C, 0x8B, 0xC2, 0x48, 0x6B, 0xD0, 0x70, 0x48, 0x8D, 0x05, 0x77,
				0x9E, 0xA6, 0x06, 0x49, 0x8B, 0xC8, 0x48, 0x8B, 0x14, 0x02, 0xE9, 0xC3, 0x00, 0xF4, 0xFF}, role_client},
			{"controller index", 0x140347690, {0x8B, 0x05, 0xCE, 0xCD, 0xEB, 0x01, 0xC3}, role_client},
			{"speex frame size", 0x140B79440, {0x8B, 0x05, 0x96, 0x32, 0x1E, 0x05, 0xC3}, role_client},
			// the capture poll reads the channel count and sample rate
			{"capture channels read", 0x140B7A3E6, {0x8B, 0x0D, 0xBC, 0x88, 0x03, 0x01}, role_client},
			{"capture rate read", 0x140B7A411, {0x8B, 0x05, 0x89, 0x88, 0x03, 0x01}, role_client},
			{"voice initialized read", 0x140D593FD, {0x83, 0x3D, 0x28, 0x6D, 0xA4, 0x06, 0x00}, role_client},
			// clientUIActives (stride 0xC4): CL_VoiceFrame runs only while isRunning (+1)
			{"client frame voice gate", 0x1409AECB7, {0x48, 0x8D, 0x2D, 0x72, 0x7F, 0x89, 0x01, 0x48, 0x69, 0xF3, 0xC4, 0x00, 0x00,
				0x00, 0x8B, 0x44, 0x2E, 0x08, 0x83, 0xF8, 0x03, 0x7C, 0x0A, 0x83, 0xF8, 0x09, 0x74, 0x05, 0x40, 0xB7, 0x01, 0xEB, 0x03,
				0x40, 0x32, 0xFF, 0x80, 0x7C, 0x2E, 0x01, 0x00, 0x0F, 0x84, 0x83, 0x00, 0x00, 0x00, 0x8B, 0xCB, 0xE8, 0xD3, 0xDF, 0x9C,
				0xFF}, role_client},
			// session users: registered +0x60, xuid +0x68, stride 0x38, 18 users; voiceRegistered +0x61; addr.type +0x74
			{"session find user", 0x140C72A00, {0x45, 0x33, 0xC9, 0x48, 0x8D, 0x41, 0x68, 0x45, 0x8B, 0xC1, 0x66, 0x0F, 0x1F, 0x44,
				0x00, 0x00, 0x80, 0x78, 0xF8, 0x00, 0x74, 0x05, 0x48, 0x39, 0x10, 0x74, 0x14, 0x41, 0xFF, 0xC1, 0x49, 0xFF, 0xC0, 0x48,
				0x83, 0xC0, 0x38, 0x49, 0x83, 0xF8, 0x12, 0x7C}, role_client},
			{"session voice user", 0x140D59990, {0x45, 0x33, 0xC9, 0x48, 0x8D, 0x41, 0x68, 0x33, 0xD2, 0x4C, 0x8B, 0xD1, 0x0F, 0x1F}, role_client},
			{"session user loopback", 0x140C732A0, {0x48, 0x63, 0xC2, 0x48, 0x6B, 0xD0, 0x38, 0x83, 0x7C, 0x0A, 0x74, 0x02, 0x0F, 0x94,
				0xC0, 0xC3}, role_client},
			{"Dvar_FindVar", 0x140CEA460, {0x48, 0x83, 0xEC, 0x28, 0xE8, 0xB7, 0x00, 0x00, 0x00, 0x8B, 0xC8, 0x48, 0x83, 0xC4, 0x28,
				0xE9, 0x4C, 0xFF, 0xFF, 0xFF}, role_client},
			{"Sys_Milliseconds", 0x140D58110, {0x83, 0x3D, 0xA5, 0x7E, 0xA4, 0x06, 0x00, 0x49, 0xB9, 0x00, 0x00, 0x00, 0x00, 0x00,
				0x00, 0x00}, role_both},
			{"Cbuf_AddText", 0x140B7C290, {0x4C, 0x63, 0xC1, 0x48, 0x8D, 0x05, 0x8E, 0x3A, 0x1F, 0x05, 0x49, 0xC1, 0xE0, 0x04, 0x4C,
				0x03, 0xC0, 0xE9, 0x0A, 0x00, 0x00, 0x00}, role_both},
			// svs: client pointer table 0x146B22950, count 0x146B229E0, state +8, remoteAddress +0x9E990
			{"server client table", 0x140C58ACA, {0x8B, 0x05, 0x10, 0x9F, 0xEC, 0x05, 0x33, 0xFF, 0x8B, 0xF2, 0x48, 0x8B, 0xE9, 0x85,
				0xC0, 0x7E, 0x5E, 0x4C, 0x8D, 0x35, 0x6E, 0x9E, 0xEC, 0x05, 0x49, 0x8B, 0x1C, 0xFE, 0x80, 0x7B, 0x08, 0x00, 0x74, 0x47,
				0x0F, 0x10, 0x83, 0x90, 0xE9, 0x09, 0x00}, role_server},
			// g_entities 0x143D22610, stride 0x3F8, client +0x170
			{"server entities", 0x140B0B993, {0x48, 0x69, 0xD8, 0xF8, 0x03, 0x00, 0x00, 0x48, 0x8D, 0x05, 0x6F, 0x6C, 0x21, 0x03, 0x48,
				0x03, 0xD8, 0x48, 0x83, 0xBB, 0x70, 0x01, 0x00, 0x00, 0x00}, role_server},
			// GSC "sessionteam" and "sessionstate" getters: gclient +0x4BE0 and +0x4A94
			{"server session team", 0x140447B90, {0x8B, 0x91, 0xE0, 0x4B, 0x00, 0x00}, role_server},
			{"server session state", 0x140447C70, {0x8B, 0x91, 0x94, 0x4A, 0x00, 0x00}, role_server},
		};

		// Built by the capture poll 0x140B7A300 and passed to the device callback
		struct capture_block
		{
			std::int16_t* data;
			int bytes;
			int samples;
			int bytes_per_sample;
			int rate;
			bool stereo;
			int channels;
			int consumed;
		};

		static_assert(offsetof(capture_block, samples) == 0xC);
		static_assert(offsetof(capture_block, bytes_per_sample) == 0x10);
		static_assert(offsetof(capture_block, channels) == 0x1C);
		static_assert(offsetof(capture_block, consumed) == 0x20);

		struct talker_recording
		{
			FILE* file{};
			std::vector<std::int16_t> pending;
			std::uint64_t samples{}; // everything received, written or pending
			std::uint64_t reported{};
			std::uint64_t buffers{};
			std::uint64_t dropped{}; // samples the playback buffer did not accept
			int last_report{};
		};

		std::filesystem::path test_dir;
		role current_role{};
		bool clock_ok{};

		std::mutex events_mutex;
		FILE* events_file{};

		std::mutex record_mutex;
		talker_recording recordings[max_talkers]{};
		std::uint64_t unattributed{};

		struct
		{
			std::uint64_t frames;
			std::uint64_t bytes;
			std::uint64_t reported;
			int last_report;
		} encoded{};

		struct
		{
			std::string file;
			std::vector<std::int16_t> samples;
			size_t position;
			bool active;
			bool started;
			int start_time;
		} play{};

		struct
		{
			int last_time;
			std::int64_t remainder; // elapsed ms * rate not yet turned into samples
			std::uint64_t samples;
			std::uint64_t device_blocks;
			std::vector<std::int16_t> block;
		} mic{};

		struct
		{
			int connection_state = -1;
			int voice_initialized = -1;
			std::uint32_t active_clients = 0xFFFFFFFF;
			std::uint64_t command_offset{};
		} watch{};

		// Events

		using json_writer = rapidjson::Writer<rapidjson::StringBuffer, rapidjson::UTF8<>, rapidjson::ASCII<>>;

		template <typename T>
		void put(json_writer& w, const char* key, const T& value)
		{
			w.Key(key);
			if constexpr (std::is_same_v<T, bool>)
			{
				w.Bool(value);
			}
			else if constexpr (std::is_convertible_v<T, std::string_view>)
			{
				const std::string_view text = value;
				w.String(text.data(), static_cast<rapidjson::SizeType>(text.size()));
			}
			else if constexpr (std::is_floating_point_v<T>)
			{
				w.Double(value);
			}
			else if constexpr (std::is_enum_v<T> || std::is_signed_v<T>)
			{
				w.Int64(static_cast<std::int64_t>(value));
			}
			else
			{
				w.Uint64(value);
			}
		}

		int now()
		{
			return clock_ok ? game::Sys_Milliseconds() : -1;
		}

		std::int64_t wall_clock()
		{
			FILETIME file_time{};
			GetSystemTimePreciseAsFileTime(&file_time);
			const auto ticks = (static_cast<std::uint64_t>(file_time.dwHighDateTime) << 32) | file_time.dwLowDateTime;
			return static_cast<std::int64_t>(ticks / 10000) - 11644473600000;
		}

		void emit(const char* name, const std::function<void(json_writer&)>& fields = {})
		{
			rapidjson::StringBuffer buffer;
			json_writer w(buffer);
			w.StartObject();
			put(w, "t", now());
			put(w, "wall", wall_clock());
			put(w, "event", name);
			if (fields)
			{
				fields(w);
			}
			w.EndObject();

			std::lock_guard _(events_mutex);
			if (events_file)
			{
				std::fwrite(buffer.GetString(), 1, buffer.GetSize(), events_file);
				std::fputc('\n', events_file);
				std::fflush(events_file);
			}
		}

		void emit_error(const std::string& message)
		{
			console::error("voicetest: %s\n", message.data());
			emit("error", [&](json_writer& w)
			{
				put(w, "message", message);
			});
		}

		void put_dvar(json_writer& w, const char* name)
		{
			const auto* dvar = game::Dvar_FindVar(name);
			if (dvar && dvar->type == game::DVAR_TYPE_BOOL)
			{
				put(w, name, dvar->current.enabled);
			}
			else if (dvar && dvar->type == game::DVAR_TYPE_FLOAT)
			{
				put(w, name, dvar->current.value);
			}
			else if (dvar && dvar->type == game::DVAR_TYPE_INT)
			{
				put(w, name, dvar->current.integer);
			}
			else
			{
				w.Key(name);
				w.Null();
			}
		}

		std::string hex(const std::uint8_t* data, const size_t size)
		{
			std::string result;
			for (size_t i = 0; i < size; i++)
			{
				result += utils::string::va("%02X", data[i]);
			}

			return result;
		}

		std::vector<const code_check*> check_code(const role roles)
		{
			std::vector<const code_check*> mismatches;
			for (const auto& check : code_checks)
			{
				if ((check.roles & roles) && std::memcmp(reinterpret_cast<const void*>(check.address), check.bytes.data(),
					check.bytes.size()) != 0)
				{
					mismatches.push_back(&check);
				}
			}

			return mismatches;
		}

		// voice.cpp registers players and reads mutes here, in the slot of their client number
		game::SessionData* get_session()
		{
			return game::g_serverSession.get();
		}

		// the session the native voice code would use (party session while a party is in game)
		game::SessionData* get_voice_session()
		{
			return utils::hook::invoke<game::SessionData*>(voice_get_session);
		}

		// the session the scoreboard mutes players in
		game::SessionData* get_scoreboard_session()
		{
			if (game::Com_FrontEndScene_IsActive())
			{
				return nullptr;
			}

			if (utils::hook::invoke<bool>(lobby_is_running))
			{
				return utils::hook::invoke<game::SessionData*>(lobby_get_session);
			}

			if (utils::hook::invoke<int>(party_is_in_game, game::g_partyData.get()))
			{
				return game::g_partyData->session;
			}

			return game::g_serverSession.get();
		}

		int get_local_talker(game::SessionData* session)
		{
			const auto controller = utils::hook::invoke<int>(controller_index, 0);
			return session ? utils::hook::invoke<int>(voice_get_local_talker, controller, session) : -1;
		}

		std::string get_session_name(const game::SessionData* session)
		{
			const auto address = reinterpret_cast<std::uintptr_t>(session);
			return address == game_session ? "game" : address == party_session ? "party" : utils::string::va("%llX", address);
		}

		// WAV files

		struct wav_header
		{
			char riff[4];
			std::uint32_t riff_size;
			char wave[4];
			char fmt[4];
			std::uint32_t fmt_size;
			std::uint16_t format;
			std::uint16_t channels;
			std::uint32_t rate;
			std::uint32_t byte_rate;
			std::uint16_t block_align;
			std::uint16_t bits;
			char data[4];
			std::uint32_t data_size;
		};

		static_assert(sizeof(wav_header) == 44);

		void write_wav_header(FILE* file, const int rate, const std::uint64_t samples)
		{
			const auto data_size = static_cast<std::uint32_t>(samples * 2);
			const wav_header header{{'R', 'I', 'F', 'F'}, 36 + data_size, {'W', 'A', 'V', 'E'}, {'f', 'm', 't', ' '}, 16, 1, 1,
				static_cast<std::uint32_t>(rate), static_cast<std::uint32_t>(rate * 2), 2, 16, {'d', 'a', 't', 'a'}, data_size};

			std::fseek(file, 0, SEEK_SET);
			std::fwrite(&header, sizeof(header), 1, file);
		}

		bool load_wav(const std::filesystem::path& path, std::vector<std::int16_t>& samples, int& rate, std::string& error)
		{
			std::ifstream stream(path, std::ios::binary);
			if (!stream)
			{
				error = "cannot open file";
				return false;
			}

			const std::string data((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
			if (data.size() < 12 || data.compare(0, 4, "RIFF") != 0 || data.compare(8, 4, "WAVE") != 0)
			{
				error = "not a RIFF/WAVE file";
				return false;
			}

			auto have_format = false;
			for (size_t position = 12; position + 8 <= data.size();)
			{
				const auto id = data.substr(position, 4);
				std::uint32_t size{};
				std::memcpy(&size, data.data() + position + 4, sizeof(size));
				const auto body = position + 8;
				if (size > data.size() - body)
				{
					error = "truncated chunk " + id;
					return false;
				}

				if (id == "fmt " && size >= 16)
				{
					std::uint16_t format{}, channels{}, bits{};
					std::memcpy(&format, data.data() + body, 2);
					std::memcpy(&channels, data.data() + body + 2, 2);
					std::memcpy(&rate, data.data() + body + 4, 4);
					std::memcpy(&bits, data.data() + body + 14, 2);
					if (format != 1 || channels != 1 || bits != 16)
					{
						error = utils::string::va("need mono 16-bit PCM, got format %u, %u channels, %u bits", format, channels, bits);
						return false;
					}

					have_format = true;
				}
				else if (id == "data" && have_format)
				{
					samples.resize(size / 2);
					std::memcpy(samples.data(), data.data() + body, samples.size() * 2);
					return true;
				}

				position = body + size + (size & 1);
			}

			error = "no fmt/data chunk";
			return false;
		}

		// Recorder: decoded PCM at the native playback enqueue, attributed through the stream table

		int pcm_enqueue_stub(void* stream, const std::int16_t* pcm, const int bytes)
		{
			const auto accepted = utils::hook::invoke<int>(pcm_enqueue, stream, pcm, bytes);
			const auto count = static_cast<size_t>(std::max(bytes, 0) / 2);

			std::lock_guard _(record_mutex);
			const auto* const end = playback_streams + max_talkers;
			const auto* const found = std::find(playback_streams, end, stream);
			if (found == end)
			{
				unattributed += count;
				return accepted;
			}

			auto& target = recordings[found - playback_streams];
			target.pending.insert(target.pending.end(), pcm, pcm + count);
			target.samples += count;
			target.buffers++;
			target.dropped += count - std::min(count, static_cast<size_t>(std::max(accepted, 0) / 2));
			return accepted;
		}

		void flush_recordings()
		{
			struct report
			{
				int talker;
				std::uint64_t samples, total, buffers, dropped;
			};

			std::vector<report> reports;
			std::vector<std::string> errors;
			{
				std::lock_guard _(record_mutex);
				const auto time_ms = now();
				for (auto i = 0; i < max_talkers; i++)
				{
					auto& target = recordings[i];
					if (!target.pending.empty())
					{
						if (!target.file)
						{
							const auto path = test_dir / utils::string::va("recv_%d.wav", i);
							target.file = _wfsopen(path.c_str(), L"w+b", _SH_DENYNO);
							if (!target.file)
							{
								errors.emplace_back(utils::string::va("cannot create recv_%d.wav", i));
								target.pending.clear();
								continue;
							}

							write_wav_header(target.file, *voice_rate, 0);
						}

						// samples counts everything received, so after this write the header covers the whole file
						std::fseek(target.file, 0, SEEK_END);
						std::fwrite(target.pending.data(), 2, target.pending.size(), target.file);
						target.pending.clear();
						write_wav_header(target.file, *voice_rate, target.samples);
						std::fflush(target.file);
					}

					if (target.samples > target.reported && time_ms - target.last_report >= report_interval)
					{
						reports.push_back({i, target.samples - target.reported, target.samples, target.buffers, target.dropped});
						target.reported = target.samples;
						target.last_report = time_ms;
					}
				}
			}

			for (const auto& message : errors)
			{
				emit_error(message);
			}

			for (const auto& entry : reports)
			{
				emit("recv", [&](json_writer& w)
				{
					put(w, "talker", entry.talker);
					put(w, "samples", entry.samples);
					put(w, "total", entry.total);
					put(w, "buffers", entry.buffers);
					put(w, "dropped", entry.dropped);
				});
			}
		}

		void put_recv_totals(json_writer& w)
		{
			std::lock_guard _(record_mutex);
			w.Key("recv");
			w.StartObject();
			for (auto i = 0; i < max_talkers; i++)
			{
				if (recordings[i].samples)
				{
					put(w, std::to_string(i).data(), recordings[i].samples);
				}
			}
			w.EndObject();
			put(w, "unattributed", unattributed);
		}

		// Virtual microphone: the only capture input while -voicetest is active

		int encoded_queue_stub(const int size, const unsigned char* data)
		{
			if (size > 0)
			{
				encoded.frames++;
				encoded.bytes += size;
			}

			return utils::hook::invoke<int>(voice_encoded_queue, size, data);
		}

		void capture_callback_stub(capture_block*)
		{
			// the real microphone never reaches the pipeline (two clients on one machine share it)
			mic.device_blocks++;
		}

		void end_play(const char* reason)
		{
			emit("play_end", [&](json_writer& w)
			{
				put(w, "file", play.file);
				put(w, "frames", play.position);
				put(w, "duration_ms", play.started ? now() - play.start_time : 0);
				put(w, "reason", reason);
			});

			play = {};
		}

		// Runs every main frame like the native capture poll (CL_VoiceFrame, while isRunning and voice is
		// initialized) and feeds the elapsed time worth of samples: the phrase while playing, else silence.
		void mic_frame()
		{
			const auto time_ms = game::Sys_Milliseconds();
			const auto rate = *voice_rate;
			if (!*voice_initialized || !game::clientUIActives[0].isRunning || rate <= 0)
			{
				mic.last_time = 0;
				return;
			}

			if (!mic.last_time)
			{
				mic.last_time = time_ms;
				mic.remainder = 0;
				return;
			}

			mic.remainder += static_cast<std::int64_t>(time_ms - mic.last_time) * rate;
			mic.last_time = time_ms;
			const auto due = mic.remainder / 1000;
			mic.remainder %= 1000;

			// after a hitch (at most 200 ms per frame) the phrase pauses instead of bursting; nothing is skipped
			const auto count = static_cast<int>(std::min<std::int64_t>(due, rate / 5));
			if (count <= 0)
			{
				return;
			}

			mic.block.assign(static_cast<size_t>(count), 0);
			if (play.active)
			{
				if (!play.started)
				{
					play.started = true;
					play.start_time = time_ms;
					emit("play_start", [&](json_writer& w)
					{
						put(w, "file", play.file);
						put(w, "frames", play.samples.size());
						put(w, "rate", rate);
					});
				}

				const auto copied = std::min(static_cast<size_t>(count), play.samples.size() - play.position);
				std::memcpy(mic.block.data(), play.samples.data() + play.position, copied * 2);
				play.position += copied;
			}

			capture_block block{mic.block.data(), count * 2, count, 2, rate, false, 1, 0};
			utils::hook::invoke<void>(voice_capture_pcm, &block);
			mic.samples += count;

			if (play.active && play.position >= play.samples.size())
			{
				end_play("complete");
			}
		}

		// Commands

		void play_command(const command::params& params)
		{
			if (params.size() < 2 || play.active)
			{
				emit("play_error", [&](json_writer& w)
				{
					put(w, "reason", play.active ? "already playing" : "usage: voicetest_play <wav>");
				});
				return;
			}

			// relative paths are inside the -voicetest directory
			std::filesystem::path path = params.join(1);
			if (path.is_relative())
			{
				path = test_dir / path;
			}

			std::vector<std::int16_t> samples;
			auto rate = 0;
			std::string error;
			if (load_wav(path, samples, rate, error))
			{
				if (rate != *voice_rate)
				{
					error = utils::string::va("sample rate %d, native capture rate %d", rate, *voice_rate);
				}
				else if (samples.empty())
				{
					error = "no samples";
				}
			}

			const auto file = utils::string::convert(path.wstring());
			if (!error.empty())
			{
				emit("play_error", [&](json_writer& w)
				{
					put(w, "file", file);
					put(w, "reason", error);
				});
				return;
			}

			play.file = file;
			play.samples = std::move(samples);
			play.active = true;
		}

		void mute_command(const command::params& params, const bool muted)
		{
			const std::string_view argument = params.size() == 2 ? params.get(1) : "";
			auto client_num = -1;
			const auto parsed = std::from_chars(argument.data(), argument.data() + argument.size(), client_num);
			auto* session = get_scoreboard_session();
			if (parsed.ec != std::errc{} || parsed.ptr != argument.data() + argument.size() || client_num < 0
				|| client_num >= max_talkers || !session)
			{
				emit_error(utils::string::va("usage: voicetest_%s <clientNum 0..17>, in game", muted ? "mute" : "unmute"));
				return;
			}

			// as the scoreboard does it; the slot is the client number when the session is the game session
			utils::hook::invoke<void>(muted ? voice_mute : voice_unmute, session, client_num);

			const auto& user = get_session()->dyn.users[client_num];
			emit("mute", [&](json_writer& w)
			{
				put(w, "client", client_num);
				put(w, "session", get_session_name(session));
				put(w, "muted", user.muted);
				put(w, "registered", user.registered);
			});
		}

		void mark_command(const command::params& params)
		{
			if (current_role == role_client)
			{
				flush_recordings();
			}

			emit("mark", [&](json_writer& w)
			{
				put(w, "label", params.join(1));
				if (current_role == role_client)
				{
					put_recv_totals(w);
					put(w, "encoded", encoded.frames);
					put(w, "playing", play.active);
				}
			});
		}

		void client_snapshot()
		{
			flush_recordings();

			auto* session = get_session();
			emit("snapshot", [&](json_writer& w)
			{
				put(w, "role", "client");
				put(w, "client_num", get_local_talker(session)); // own game session slot = server clientNum
				w.Key("team"); // the server snapshot reports teams
				w.Null();
				put(w, "connection_state", game::clientUIActives[0].connectionState);
				put_dvar(w, "cl_voice");
				put_dvar(w, "cl_pushToTalk");
				put_dvar(w, "winvoice_mic_threshold");
				put_dvar(w, "rate");
				put(w, "voice_initialized", *voice_initialized != 0);
				put(w, "frame_size", *voice_initialized ? utils::hook::invoke<int>(speex_frame_size) : 0);
				put(w, "rate_native", *voice_rate);
				put(w, "mic_samples", mic.samples);
				put(w, "device_blocks", mic.device_blocks);
				put(w, "encoded", encoded.frames);
				put(w, "playing", play.active);
				put_recv_totals(w);
				put(w, "session", get_session_name(session));
				put(w, "session_active", session && session->dyn.sessionHandle);
				put(w, "voice_session", get_session_name(get_voice_session()));
				const auto* scoreboard_session = get_scoreboard_session();
				put(w, "scoreboard_session", scoreboard_session ? get_session_name(scoreboard_session) : "none");

				w.Key("users");
				w.StartArray();
				for (auto i = 0; session && i < max_talkers; i++)
				{
					const auto& user = session->dyn.users[i];
					w.StartObject();
					put(w, "slot", i);
					put(w, "registered", user.registered);
					put(w, "voice_registered", user.voiceRegistered);
					put(w, "xuid", utils::string::va("%016llX", user.xuid));
					put(w, "addr_type", user.addr.type); // 2 loopback, 4 ip
					put(w, "muted", user.muted);
					w.EndObject();
				}
				w.EndArray();
			});
		}

		void server_snapshot()
		{
			emit("snapshot", [&](json_writer& w)
			{
				put(w, "role", "server");
				w.Key("clients");
				w.StartArray();
				for (auto i = 0u; i < std::min(*game::svs_numclients, static_cast<unsigned int>(max_talkers)); i++)
				{
					const auto* client = game::svs_clients[i];
					if (!client || client->header.state == game::CS_FREE)
					{
						continue;
					}

					const auto* player = client->header.state == game::CS_ACTIVE ? game::g_entities[i].client : nullptr;
					w.StartObject();
					put(w, "num", i);
					put(w, "state", client->header.state);
					put(w, "addr_type", client->remoteAddress.type);
					put(w, "team", player ? player->sess.cs.team : -1); // 0 free, 1 axis, 2 allies, 3 spectator
					put(w, "session_state", player ? player->sess.sessionState : -1); // 0 playing, 1 dead, 2 spectator, 3 intermission
					w.EndObject();
				}
				w.EndArray();
			});
		}

		// Command channel and periodic state

		void poll_commands()
		{
			const auto handle = CreateFileW((test_dir / "commands.txt").c_str(), GENERIC_READ,
				FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
			if (handle == INVALID_HANDLE_VALUE)
			{
				return;
			}

			const auto _ = gsl::finally([&]
			{
				CloseHandle(handle);
			});

			LARGE_INTEGER size{};
			if (!GetFileSizeEx(handle, &size))
			{
				return;
			}

			const auto file_size = static_cast<std::uint64_t>(size.QuadPart);
			if (file_size < watch.command_offset)
			{
				emit("commands_reset");
				watch.command_offset = 0;
			}

			if (file_size == watch.command_offset)
			{
				return;
			}

			LARGE_INTEGER position{};
			position.QuadPart = static_cast<LONGLONG>(watch.command_offset);
			std::string data(static_cast<size_t>(std::min<std::uint64_t>(file_size - watch.command_offset, max_command_read)), '\0');
			DWORD read{};
			if (!SetFilePointerEx(handle, position, nullptr, FILE_BEGIN)
				|| !ReadFile(handle, data.data(), static_cast<DWORD>(data.size()), &read, nullptr))
			{
				return;
			}

			data.resize(read);
			const auto end = data.rfind('\n');
			if (end == std::string::npos)
			{
				// a line is complete only once its newline is written
				if (data.size() == max_command_read)
				{
					emit_error("command line longer than 64 KiB skipped");
					watch.command_offset += data.size();
				}
				return;
			}

			const auto first_line = watch.command_offset == 0;
			watch.command_offset += end + 1;

			std::istringstream lines(data.substr(0, end));
			for (std::string line; std::getline(lines, line); )
			{
				if (first_line && line.starts_with("\xEF\xBB\xBF"))
				{
					line.erase(0, 3);
				}

				while (!line.empty() && (line.back() == '\r' || line.back() == ' ' || line.back() == '\t'))
				{
					line.pop_back();
				}

				if (!line.empty())
				{
					emit("command", [&](json_writer& w)
					{
						put(w, "text", line);
					});
					command::execute(line);
				}
			}
		}

		void report_encoded()
		{
			const auto time_ms = now();
			if (encoded.frames > encoded.reported && time_ms - encoded.last_report >= report_interval)
			{
				emit("encoded", [&](json_writer& w)
				{
					put(w, "frames", encoded.frames - encoded.reported);
					put(w, "total", encoded.frames);
					put(w, "bytes", encoded.bytes);
				});
				encoded.reported = encoded.frames;
				encoded.last_report = time_ms;
			}
		}

		void watch_client()
		{
			const auto state = static_cast<int>(game::clientUIActives[0].connectionState);
			if (state != watch.connection_state)
			{
				watch.connection_state = state;
				emit("connection", [&](json_writer& w)
				{
					put(w, "state", state); // 9 = active
				});
			}

			const auto initialized = *voice_initialized != 0 ? 1 : 0;
			if (initialized != watch.voice_initialized)
			{
				watch.voice_initialized = initialized;
				const auto frame_size = initialized ? utils::hook::invoke<int>(speex_frame_size) : 0;
				emit("voice_state", [&](json_writer& w)
				{
					put(w, "initialized", initialized != 0);
					put(w, "frame_size", frame_size);
					put(w, "rate", *voice_rate);
					put(w, "frame_ms", *voice_rate > 0 ? frame_size * 1000.0 / *voice_rate : 0.0);
				});
			}
		}

		void watch_server()
		{
			std::uint32_t active{};
			for (auto i = 0u; i < std::min(*game::svs_numclients, static_cast<unsigned int>(max_talkers)); i++)
			{
				const auto* client = game::svs_clients[i];
				if (client && client->header.state == game::CS_ACTIVE)
				{
					active |= 1u << i;
				}
			}

			if (active != watch.active_clients)
			{
				watch.active_clients = active;
				emit("clients", [&](json_writer& w)
				{
					put(w, "active", active);
					put(w, "count", std::popcount(active));
				});
			}
		}

		void periodic()
		{
			poll_commands();

			if (current_role == role_client)
			{
				flush_recordings();
				report_encoded();
				watch_client();
			}
			else
			{
				watch_server();
			}
		}

		std::optional<std::filesystem::path> get_test_dir()
		{
			auto count = 0;
			auto* const args = CommandLineToArgvW(GetCommandLineW(), &count);
			if (!args)
			{
				return {};
			}

			std::optional<std::filesystem::path> result{};
			for (auto i = 0; i + 1 < count; i++)
			{
				if (_wcsicmp(args[i], L"-voicetest") == 0)
				{
					result = args[i + 1];
					break;
				}
			}

			LocalFree(args);
			return result;
		}

		void install_client()
		{
			utils::hook::jump(capture_callback_thunk, capture_callback_stub);
			utils::hook::call(encoded_queue_call, encoded_queue_stub);
			utils::hook::call(pcm_enqueue_call, pcm_enqueue_stub);

			scheduler::loop(mic_frame, scheduler::pipeline::main);

			command::add("voicetest_play", play_command);
			command::add("voicetest_stop", []
			{
				if (play.active)
				{
					end_play("stopped");
				}
			});
			command::add("voicetest_mute", [](const command::params& params)
			{
				mute_command(params, true);
			});
			command::add("voicetest_unmute", [](const command::params& params)
			{
				mute_command(params, false);
			});
			command::add("voicetest_snapshot", client_snapshot);
		}
	}

	class component final : public component_interface
	{
	public:
		void post_unpack() override
		{
			const auto dir = get_test_dir();
			if (!dir)
			{
				return;
			}

			std::error_code error{};
			if (dir->is_absolute())
			{
				std::filesystem::create_directories(*dir, error);
			}

			if (!dir->is_absolute() || error)
			{
				console::error("voicetest: -voicetest needs an absolute, writable directory\n");
				return;
			}

			test_dir = *dir;
			events_file = _wfsopen((test_dir / "events.jsonl").c_str(), L"ab", _SH_DENYNO);
			if (!events_file)
			{
				console::error("voicetest: cannot open events.jsonl\n");
				return;
			}

			current_role = game::environment::is_dedi() ? role_server : role_client;
			const auto mismatches = check_code(current_role);
			clock_ok = std::none_of(mismatches.begin(), mismatches.end(), [](const code_check* check)
			{
				return check->address == reinterpret_cast<std::uintptr_t>(game::Sys_Milliseconds.get());
			});

			for (const auto* check : mismatches)
			{
				emit("error", [&](json_writer& w)
				{
					put(w, "message", "engine code differs from the verified retail bytes");
					put(w, "check", check->name);
					put(w, "address", utils::string::va("%llX", check->address));
					put(w, "expected", hex(check->bytes.data(), check->bytes.size()));
					put(w, "actual", hex(reinterpret_cast<const std::uint8_t*>(check->address), check->bytes.size()));
				});
			}

			const auto ok = mismatches.empty();
			emit("start", [&](json_writer& w)
			{
				put(w, "ok", ok);
				put(w, "role", current_role == role_client ? "client" : "server");
				put(w, "pid", GetCurrentProcessId());
				put(w, "dir", utils::string::convert(test_dir.wstring()));
				put(w, "checks", std::count_if(code_checks.begin(), code_checks.end(), [](const code_check& check)
				{
					return (check.roles & current_role) != 0;
				}));
				if (current_role == role_client)
				{
					// native capture and playback format; static data, verified through its readers
					put(w, "rate", *voice_rate);
					put(w, "channels", *voice_channels);
				}
			});

			if (!ok)
			{
				console::error("voicetest: engine code mismatch, staying inert\n");
				return;
			}

			if (current_role == role_client)
			{
				install_client();
			}
			else
			{
				command::add("voicetest_snapshot", server_snapshot);
			}

			command::add("voicetest_mark", mark_command);
			scheduler::loop(periodic, scheduler::pipeline::main, 250ms);
		}

		void pre_destroy() override
		{
			if (!events_file)
			{
				return;
			}

			if (current_role == role_client)
			{
				flush_recordings();
			}

			emit("stop");

			std::lock_guard _(record_mutex);
			for (auto& target : recordings)
			{
				if (target.file)
				{
					std::fclose(target.file);
					target.file = nullptr;
				}
			}
		}
	};
}

REGISTER_COMPONENT(voice_test::component)
