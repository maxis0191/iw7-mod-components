#include <std_include.hpp>
#include "loader/component_loader.hpp"

#include "command.hpp"
#include "console/console.hpp"
#include "game/game.hpp"
#include "paris_console_writer.hpp"

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
				console_log_stream().flush();
			});

			instance->start();
			active().store(instance, std::memory_order_release);

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
			console_log_stream().close_all();
		}
	};
}

REGISTER_COMPONENT(paris_console_writer::component)
