#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "download.hpp"
#include "console/console.hpp"
#include "scheduler.hpp"
#include "party.hpp"
#include "game/ui_scripting/execution.hpp"
#include "utils/hash.hpp"
#include <utils/concurrency.hpp>
#include <utils/http.hpp>
#include <array>
#include <filesystem>

namespace download
{
	namespace
	{
		struct globals_t
		{
			bool abort{};
			bool active{};
			uint64_t generation{};
			uint64_t cancellation_serial{};
		};

		std::atomic_bool kill_downloads = false;
		utils::concurrency::container<globals_t> globals;
		constexpr auto cancelled_message = "Download cancelled.";
		constexpr auto network_message = "The mod could not be downloaded. Please try again.";
		constexpr auto integrity_message = "The downloaded mod could not be verified. Please try again.";
		constexpr auto storage_message = "The mod could not be saved. Check available space and folder permissions.";
		constexpr auto completion_message = "The download could not be completed. Please try again.";

		bool current(const uint64_t generation)
		{
			return !kill_downloads && globals.access<bool>([=](globals_t& state)
			{
				return state.generation == generation;
			});
		}

		bool cancelled(const uint64_t generation)
		{
			return kill_downloads || globals.access<bool>([=](globals_t& state)
			{
				return state.generation != generation || state.abort;
			});
		}

		void check_cancelled(const uint64_t generation)
		{
			if (cancelled(generation)) throw cancelled_message;
		}

		// This object owns only a CREATE_NEW file in the destination directory.
		// Never truncate, delete or move the previous destination before commit.
		struct temporary_file
		{
			std::filesystem::path path;
			HANDLE handle = INVALID_HANDLE_VALUE;
			bool owned = false;

			~temporary_file() noexcept
			{
				if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
				if (owned) DeleteFileW(path.c_str());
			}

			void close()
			{
				if (!CloseHandle(handle)) throw storage_message;
				handle = INVALID_HANDLE_VALUE;
			}
		};

		void publish_file(const file_t& file, const std::string& bytes, const uint64_t generation)
		{
			check_cancelled(generation);
			const auto destination = std::filesystem::path(file.name);
			if (destination.has_parent_path()) std::filesystem::create_directories(destination.parent_path());
			static std::atomic_uint64_t sequence{};
			temporary_file temporary;
			for (unsigned attempt = 0; attempt != 64; ++attempt)
			{
				temporary.path = destination;
				temporary.path += ".iw7-download-" + std::to_string(GetCurrentProcessId()) + "-" +
					std::to_string(++sequence) + ".tmp";
				temporary.handle = CreateFileW(temporary.path.c_str(), GENERIC_WRITE, 0, nullptr,
					CREATE_NEW, FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
				if (temporary.handle != INVALID_HANDLE_VALUE)
				{
					temporary.owned = true;
					break;
				}
				if (GetLastError() != ERROR_FILE_EXISTS && GetLastError() != ERROR_ALREADY_EXISTS) throw storage_message;
			}
			if (!temporary.owned) throw storage_message;

			constexpr size_t chunk_size = 64 * 1024;
			for (size_t offset = 0; offset < bytes.size();)
			{
				check_cancelled(generation);
				const auto count = static_cast<DWORD>((std::min)(chunk_size, bytes.size() - offset));
				DWORD written = 0;
				if (!WriteFile(temporary.handle, bytes.data() + offset, count, &written, nullptr) || written != count)
					throw storage_message;
				offset += written;
			}
			if (!FlushFileBuffers(temporary.handle)) throw storage_message;
			temporary.close();

			// Reopen exclusively after close: verify size and every byte actually persisted.
			temporary.handle = CreateFileW(temporary.path.c_str(), GENERIC_READ, 0, nullptr,
				OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
			if (temporary.handle == INVALID_HANDLE_VALUE) throw storage_message;
			LARGE_INTEGER size{};
			if (!GetFileSizeEx(temporary.handle, &size) || size.QuadPart < 0 ||
				static_cast<uint64_t>(size.QuadPart) != bytes.size()) throw storage_message;
			std::array<char, chunk_size> buffer{};
			for (size_t offset = 0; offset < bytes.size();)
			{
				check_cancelled(generation);
				const auto count = static_cast<DWORD>((std::min)(buffer.size(), bytes.size() - offset));
				DWORD read = 0;
				if (!ReadFile(temporary.handle, buffer.data(), count, &read, nullptr) || read != count ||
					std::memcmp(buffer.data(), bytes.data() + offset, count) != 0) throw storage_message;
				offset += read;
			}
			temporary.close();
			check_cancelled(generation);
			// Same-directory rename, no COPY_ALLOWED fallback and no delete-then-move.
			if (!MoveFileExW(temporary.path.c_str(), destination.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
				throw storage_message;
			temporary.owned = false;
		}

		void finish(const uint64_t generation, const game::netadr_s target, const char* message)
		{
			// Com_SetLocalizedErrorMessage and party::connect follow party.cpp's main-thread path.
			scheduler::once([=]() noexcept
			{
				try
				{
					if (!current(generation)) return;
					scheduler::once([=]
					{
						if (current(generation)) ui_scripting::notify("mod_download_done", {});
					}, scheduler::pipeline::lui);
					enum class completion { obsolete, cancelled, failed, connect };
					const auto decision = globals.access<completion>([=](globals_t& state)
					{
						if (kill_downloads || state.generation != generation || !state.active) return completion::obsolete;
						const auto aborted = state.abort;
						state.abort = state.abort || message != nullptr;
						// Linearization point shared with stop_download: active stays true
						// through all fallible enqueue work. A stop winning this mutex first
						// cancels; a stop after this terminal commit cannot retract connect.
						state.active = false;
						return aborted ? completion::cancelled : message ? completion::failed : completion::connect;
					});
					// No queue or UI work between the decision and connect; no globals
					// mutex held across reentrant party/game APIs.
					if (decision == completion::connect) party::connect(target);
					else if (decision == completion::cancelled) game::shared::menu_error(cancelled_message);
					else if (decision == completion::failed) game::shared::menu_error(message);
				}
				catch (...)
				{
					// The main callback runs later, outside finish_noexcept's enqueue catch.
					// If its LUI enqueue fails, stop here: never connect or escape main.
					try
					{
						globals.access([=](globals_t& state)
						{
							if (state.generation == generation) { state.abort = true; state.active = false; }
						});
						if (current(generation)) game::shared::menu_error(completion_message);
					}
					catch (...) {}
				}
			}, scheduler::pipeline::main);
		}

		void finish_noexcept(const uint64_t generation, const game::netadr_s target, const char* message) noexcept
		{
			try { finish(generation, target, message); }
			catch (...)
			{
				// Scheduler allocation failure must not escape the asynchronous worker.
				// No reconnect is queued. UI delivery cannot be promised without a queue.
				try
				{
					globals.access([=](globals_t& state)
					{
						if (state.generation == generation) { state.abort = true; state.active = false; }
					});
				}
				catch (...) {}
			}
		}

		int progress_callback(const uint64_t generation, const size_t total, const size_t progress) noexcept
		{
			try
			{
				if (cancelled(generation)) return -1;
				static auto last_update = std::chrono::steady_clock::now();
				const auto now = std::chrono::steady_clock::now();
				if (now - last_update > 20ms)
				{
					last_update = now;
					const auto fraction = total ? static_cast<float>(static_cast<double>(progress) / static_cast<double>(total)) : 0.f;
					scheduler::once([=]
					{
						if (!cancelled(generation)) ui_scripting::notify("mod_download_progress", {{"fraction", fraction}});
					}, scheduler::pipeline::lui);
				}
				return 0;
			}
			catch (...) { return -1; }
		}
	}

	void start_download(const game::netadr_s& target, const utils::info_string& info, const std::vector<file_t>& files)
	{
		if (kill_downloads) return;
		const auto state = globals.access<globals_t>([](globals_t& value) { return value; });
		if (state.active)
		{
			scheduler::schedule([=]
			{
				const auto now = globals.access<globals_t>([](globals_t& value) { return value; });
				// party::download_files explicitly calls stop then start when switching targets.
				// Allow that replacement, but a later stop cancels this queued intent too.
				if (kill_downloads || now.generation != state.generation || now.cancellation_serial != state.cancellation_serial ||
					(now.abort && !state.abort)) return scheduler::cond_end;
				if (now.active) return scheduler::cond_continue;
				start_download(target, info, files);
				return scheduler::cond_end;
			}, scheduler::pipeline::main);
			return;
		}

		// Reserve synchronously, so stop_download also cancels a not-yet-started worker.
		const auto generation = globals.access<uint64_t>([](globals_t& value)
		{
			value.active = true;
			value.abort = false;
			return ++value.generation;
		});
		try
		{
			const auto base = info.get("sv_wwwBaseUrl");
			if (base.empty()) { finish_noexcept(generation, target, network_message); return; }
			scheduler::once([=]
			{
				if (!cancelled(generation)) ui_scripting::notify("mod_download_start", {});
			}, scheduler::pipeline::lui);
			scheduler::once([=]() noexcept
			{
				const char* failure = nullptr;
				try
				{
					check_cancelled(generation);
					for (const auto& file : files)
					{
						check_cancelled(generation);
						scheduler::once([=]
						{
							if (cancelled(generation)) return;
							const ui_scripting::table data_table{};
							data_table.set("name", file.name.data());
							ui_scripting::notify("mod_download_set_file", {{"request", data_table}});
						}, scheduler::pipeline::lui);
						auto data = utils::http::get_data(base + "/" + file.name, {}, {}, [=](size_t total, size_t progress)
						{
							return progress_callback(generation, total, progress);
						});
						check_cancelled(generation);
						if (!data || data->code != CURLE_OK || data->response_code < 200 || data->response_code >= 300)
							throw network_message;
						if (utils::hash::get_buffer_hash(data->buffer, file.name) != file.hash) throw integrity_message;
						try { publish_file(file, data->buffer, generation); }
						catch (const char*) { throw; }
						catch (...) { throw storage_message; }
					}
					check_cancelled(generation);
				}
				catch (const char* message) { failure = message; }
				catch (...) { failure = network_message; }
				finish_noexcept(generation, target, failure);
			}, scheduler::pipeline::async);
		}
		catch (...) { finish_noexcept(generation, target, network_message); }
	}

	void stop_download()
	{
		globals.access([](globals_t& state)
		{
			++state.cancellation_serial;
			if (state.active) state.abort = true;
		});
	}

	class component final : public component_interface
	{
	public:
		void pre_destroy() override { kill_downloads = true; }
	};
}

REGISTER_COMPONENT(download::component)
