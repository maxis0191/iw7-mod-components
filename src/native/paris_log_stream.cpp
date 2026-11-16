#include <std_include.hpp>
#include "loader/component_loader.hpp"

#include "paris_log_stream.hpp"
#include "scheduler.hpp"
#include "scripting.hpp"

namespace paris_log_stream
{
	class component final : public component_interface
	{
	public:
		void post_unpack() override
		{
			// Once per server frame: what G_LogPrintf wrote during the frame reaches the file in one write.
			scheduler::loop([]()
			{
				instance().flush();
			}, scheduler::pipeline::server);

			// A map change or a script shutdown: nothing waits in the buffer across it.
			scripting::on_shutdown([](bool, bool)
			{
				instance().flush();
			});
		}

		void pre_destroy() override
		{
			instance().flush();
			instance().close_all();
		}
	};
}

REGISTER_COMPONENT(paris_log_stream::component)
