#include <std_include.hpp>
#include "loader/component_loader.hpp"

#include "command.hpp"
#include "console/console.hpp"
#include "game/game.hpp"
#include "paris_console_writer.hpp"
#include "paris_log_stream.hpp"

#include <utils/flags.hpp>

#include <cstdlib>

// The console and log writer of the dedicated server (docs/CONSOLE-WRITER.md). On by default; -paris-no-console-writer turns it off (A/B runs).
// console.cpp and terminal.cpp of the pinned iw7-mod are edited by ops/frame-cuts/frame-cut-edits.json: console::dispatch_message offers each
// line to paris_console_writer::submit, and the writer thread calls console::dispatch_message_queued (the old sinks, the kept log handle).
namespace console
{
	void dispatch_message_queued(int type, const std::string& message);
}

namespace paris_console_writer
{
	namespace
	{
		writer* instance;

		LONG CALLBACK crash_handler(PEXCEPTION_POINTERS info)
		{
			switch (info->ExceptionRecord->ExceptionCode)
			{
			case EXCEPTION_ACCESS_VIOLATION:
			case EXCEPTION_ILLEGAL_INSTRUCTION:
			case EXCEPTION_PRIV_INSTRUCTION:
			case EXCEPTION_IN_PAGE_ERROR:
			{
				// The writer thread keeps writing while this thread waits (a crash of the server thread is where the last lines matter most).
				// A first-chance exception the engine handles itself costs nothing here when the ring is empty, which is the usual case.
				if (instance && instance->running())
				{
					instance->wait_until_drained(std::chrono::milliseconds(100));
				}
				break;
			}
			default:
				break;
			}

			return EXCEPTION_CONTINUE_SEARCH;
		}

		void print_stats()
		{
			if (!instance)
			{
				return;
			}

			console::info("%s", writer::format(instance->get()).data());
		}

		void stop_writer()
		{
			if (instance)
			{
				instance->stop();
			}
		}
	}

	class component final : public component_interface
	{
	public:
		void post_unpack() override
		{
			if (!game::environment::is_dedi() || utils::flags::has_flag("paris-no-console-writer"))
			{
				return;
			}

			instance = new writer([](const int type, const std::string& message)
			{
				console::dispatch_message_queued(type, message);
			}, []
			{
				// The kept console.log handle: what a batch wrote reaches the file before the next wait, so a tool that tails it is a few ms behind.
				paris_log_stream::instance().flush();
			});

			instance->start();
			active().store(instance, std::memory_order_release);

			AddVectoredExceptionHandler(1, crash_handler);
			std::atexit(stop_writer);

			command::add("paris_console_writer_stats", [](const command::params&)
			{
				print_stats();
			});

			console::info("[console writer] ready: console lines go through a ring of 4096 lines and one writer thread\n");
		}

		void pre_destroy() override
		{
			// New lines print on the calling thread again; the writer writes what is queued, prints its counters and ends.
			active().store(nullptr, std::memory_order_release);
			stop_writer();
		}
	};
}

REGISTER_COMPONENT(paris_console_writer::component)
