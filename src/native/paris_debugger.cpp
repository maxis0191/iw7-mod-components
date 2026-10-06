#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "scheduler.hpp"
#include "gsc/script_extension.hpp"
#include <utils/flags.hpp>
#include "paris_debugger.hpp"
#include "debugger_stats.hpp"
#include <fstream>

namespace paris_debugger
{
    namespace
    {
        constexpr std::size_t slots = 0x2200;
        iw7::debugger::counters<slots> stats;
        std::atomic<bool> enabled{false};
        std::ofstream output;
        std::mutex output_mutex;
        std::uint64_t deadline{};
        std::size_t bytes{};
        std::uint64_t now_ns() noexcept
        {
            return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count());
        }
        void flush()
        {
            std::lock_guard<std::mutex> output_lock(output_mutex);
            if (!enabled.load(std::memory_order_acquire)) return;
            const auto snapshot = stats.take();
            std::ostringstream buffer;
            const auto tick = GetTickCount64();
            for (std::size_t id = 0; id < snapshot.size(); ++id)
            {
                const auto& c = snapshot[id];
                if (!c.started && !c.calls && !c.failed_clock) continue;
                const char* category = id >= 0x2100 ? "gsc_region" : id >= 0x1100 ? "gsc_method" : id >= 0x100 ? "gsc_function" : "engine_scope";
                const auto token = id >= 0x2100 ? id - 0x2100 : id >= 0x1100 ? id - 0x1100 + 0x8000 : id >= 0x100 ? id - 0x100 : id;
                buffer << "{\"type\":\"timing\",\"tick_ms\":" << tick << ",\"category\":\"" << category
                    << "\",\"id\":" << token << ",\"started\":" << c.started << ",\"calls\":" << c.calls
                    << ",\"total_us\":" << static_cast<double>(c.total_ns) / 1000.0
                    << ",\"max_us\":" << static_cast<double>(c.max_ns) / 1000.0
                    << ",\"failed_clock\":" << c.failed_clock << "}\n";
            }
            const auto text = buffer.str();
            if (bytes + text.size() <= 16 * 1024 * 1024) { output << text; output.flush(); bytes += text.size(); }
            else { enabled.store(false); output.close(); return; }
            if (tick >= deadline)
            {
                output << "{\"type\":\"complete\",\"reason\":\"duration_or_size_limit\"}\n";
                output.flush(); enabled.store(false); output.close(); return;
            }
            if (!output) enabled.store(false);
        }
    }
    std::uint64_t begin(std::size_t id) noexcept
    {
        if (!enabled.load(std::memory_order_acquire)) return 0;
        try { if (stats.begin(id)) return now_ns(); } catch (...) {}
        return 0;
    }
    void end(std::size_t id, std::uint64_t start) noexcept
    {
        if (!start || !enabled.load(std::memory_order_acquire)) return;
        try { stats.end(id, start, now_ns()); } catch (...) {}
    }
    class component final : public component_interface
    {
        void post_unpack() override
        {
            if (!utils::flags::has_flag("paris-debugger") || !utils::flags::has_flag("paris-isolated-lab")) return;
            // Fixed anonymous region IDs; no player text, engine memory reads,
            // game commands, arbitrary filenames or global dvar registration.
            gsc::function::add("paris_debug_begin", [](const gsc::function_args& args) -> scripting::script_value
            {
                const auto id = args[0].as<int>();
                if (id < 0 || id >= 256) return 0.0f;
                const auto start = begin(0x2100 + static_cast<std::size_t>(id));
                // Return milliseconds relative to a bounded run, preserving
                // float precision better than an absolute nanosecond timestamp.
                return start ? static_cast<float>((start - epoch_) / 1000000.0) + 1.0f : 0.0f;
            });
            gsc::function::add("paris_debug_end", [](const gsc::function_args& args) -> scripting::script_value
            {
                const auto id = args[0].as<int>(); const auto token = args[1].as<float>();
                if (id >= 0 && id < 256 && std::isfinite(token) && token >= 1.0f && token <= 120001.0f)
                    end(0x2100 + static_cast<std::size_t>(id), epoch_ + static_cast<std::uint64_t>((token - 1.0f) * 1000000.0f));
                return {};
            });
            scheduler::once([]
            {
                std::lock_guard<std::mutex> output_lock(output_mutex);
                const auto name = std::string("iw7-debugger-") + std::to_string(GetCurrentProcessId()) + "-" + std::to_string(GetTickCount64()) + ".jsonl";
                // CWD is the isolated lab game root, never production.
                output.open(name, std::ios::out | std::ios::binary);
                if (!output) return;
                output << "{\"type\":\"header\",\"schema\":\"iw7.debugger/1\",\"scenario\":\"instrumented laboratory\",\"pid\":"
                    << GetCurrentProcessId() << ",\"limits\":\"Inclusive wall scopes, not all GSC functions or renderer frames; interrupted VM scopes may not complete.\"}\n";
                output.flush(); epoch_ = now_ns(); deadline = GetTickCount64() + 120000; enabled.store(true);
            }, scheduler::pipeline::main);
            scheduler::loop(flush, scheduler::pipeline::async, std::chrono::seconds(1));
        }
        void pre_destroy() override
        {
            std::lock_guard<std::mutex> output_lock(output_mutex);
            enabled.store(false);
            if (output.is_open()) { output << "{\"type\":\"complete\",\"reason\":\"shutdown\"}\n"; output.flush(); output.close(); }
        }
        static std::uint64_t epoch_;
    };
    std::uint64_t component::epoch_{};
}
REGISTER_COMPONENT(paris_debugger::component)
