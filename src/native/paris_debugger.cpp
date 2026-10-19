#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "scheduler.hpp"
#include "gsc/script_extension.hpp"
#include <utils/flags.hpp>
#include "paris_debugger.hpp"
#include "debugger_stats.hpp"
#include <fstream>
#include <dxgi1_4.h>
#include <wrl/client.h>

namespace paris_debugger
{
    namespace
    {
        constexpr std::size_t slots = 0x2200;
        iw7::debugger::counters<slots> stats;
        iw7::debugger::frames<8> render_stats;
        iw7::debugger::thread_cpu_counters scope2_cpu;
        std::atomic<bool> scope2_cpu_enabled{false};
        std::atomic<std::uint64_t> scope2_cpu_internal_errors{0};
        std::atomic<unsigned> dropped_swapchains{0};
        std::mutex gpu_mutex;
        DXGI_QUERY_VIDEO_MEMORY_INFO gpu_info{};
        HRESULT gpu_status = E_PENDING;
        std::uint64_t gpu_tick{};
        std::atomic<bool> enabled{false};
        std::ofstream output;
        std::mutex output_mutex;
        std::uint64_t deadline{};
        std::size_t bytes{};
        std::atomic<int> last_game_time{-1};
        std::atomic<unsigned> server_ticks{0};
        std::atomic<unsigned> game_resets{0};
        std::uint64_t last_flush{};
        std::uint64_t now_ns() noexcept
        {
            return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count());
        }
        void write_cpu_sample(std::ostream& out, const iw7::debugger::thread_cpu_sample& s)
        {
            out << "{\"before_ns\":\"" << std::to_string(s.before_ns) << "\",\"after_ns\":\"" << std::to_string(s.after_ns)
                << "\",\"kernel_100ns\":\"" << std::to_string(s.kernel_100ns) << "\",\"user_100ns\":\"" << std::to_string(s.user_100ns) << "\"}";
        }
        void write_cpu_snapshot(std::ostream& out, const iw7::debugger::thread_cpu_snapshot& v, std::uint64_t tick)
        {
            const auto field = [&](const char* name, std::uint64_t n) { out << ",\"" << name << "\":\"" << std::to_string(n) << '"'; };
            out << "{\"type\":\"scope2_thread_cpu_quality\",\"tick_ms\":" << tick;
            field("started", v.started); field("completed", v.completed); field("paired", v.paired); field("active", v.active);
            field("api_failures", v.api_failures); field("identity_failures", v.identity_failures);
            field("clock_failures", v.clock_failures); field("cpu_rollbacks", v.cpu_rollbacks);
            field("capacity_drops", v.capacity_drops); field("invalid_tokens", v.invalid_tokens); field("cpu_overflows", v.cpu_overflows);
            field("internal_errors", scope2_cpu_internal_errors.exchange(0));
            out << ",\"last_api_error\":" << v.last_api_error << ",\"saturated\":" << (v.saturated ? "true" : "false") << "}\n";
            for (const auto& c : v.cohorts)
            {
                if (!c.tid || (!c.started && !c.completed && !c.active)) continue;
                out << "{\"type\":\"scope2_thread_cpu\",\"tick_ms\":" << tick << ",\"id\":2,\"tid\":" << c.tid;
                field("creation_filetime_100ns", c.creation_100ns);
                field("started", c.started); field("completed", c.completed); field("paired", c.paired); field("active", c.active);
                const auto paired_field = [&](const char* name, std::uint64_t n)
                { if (c.paired) field(name, n); else out << ",\"" << name << "\":null"; };
                paired_field("paired_kernel_100ns", c.kernel_100ns); paired_field("paired_user_100ns", c.user_100ns); paired_field("paired_cpu_100ns", c.cpu_100ns);
                paired_field("paired_wall_lower_ns", c.wall_lower_ns); paired_field("paired_wall_upper_ns", c.wall_upper_ns);
                paired_field("max_wall_lower_ns", c.max_wall_lower_ns); paired_field("max_wall_upper_ns", c.max_wall_upper_ns);
                paired_field("acquisition_ns", c.acquisition_ns); paired_field("max_acquisition_ns", c.max_acquisition_ns);
                out << ",\"saturated\":" << (c.saturated ? "true" : "false") << ",\"acquisition_only_ratio_min\":";
                if (!v.saturated && !c.saturated && c.paired && c.wall_upper_ns)
                    out << static_cast<double>(c.cpu_100ns) * 100.0 / c.wall_upper_ns;
                else out << "null";
                out << ",\"acquisition_only_ratio_max\":";
                if (!v.saturated && !c.saturated && c.paired && c.wall_lower_ns)
                    out << static_cast<double>(c.cpu_100ns) * 100.0 / c.wall_lower_ns;
                else out << "null";
                out << ",\"majority_classification\":\"indeterminate_cpu_resolution_unmeasured\",\"wall_lower_histogram\":[";
                for (std::size_t i = 0; i < c.wall_lower_histogram.size(); ++i)
                    out << (i ? ",\"" : "\"") << std::to_string(c.wall_lower_histogram[i]) << '"';
                out << "],\"cpu_100ns_histogram\":[";
                for (std::size_t i = 0; i < c.cpu_histogram.size(); ++i)
                    out << (i ? ",\"" : "\"") << std::to_string(c.cpu_histogram[i]) << '"';
                out << "],\"last_start\":";
                if (c.paired) write_cpu_sample(out, c.last_start); else out << "null";
                out << ",\"last_end\":";
                if (c.paired) write_cpu_sample(out, c.last_end); else out << "null";
                out << "}\n";
            }
        }
        void flush()
        {
            std::lock_guard<std::mutex> output_lock(output_mutex);
            if (!enabled.load(std::memory_order_acquire)) return;
            const auto snapshot = stats.take();
            std::ostringstream buffer;
            const auto tick = GetTickCount64();
            if (scope2_cpu_enabled.load(std::memory_order_relaxed)) write_cpu_snapshot(buffer, scope2_cpu.take(), tick);
            const auto rendering = render_stats.take();
            for (std::size_t i = 0; i < rendering.size(); ++i)
            {
                const auto& v = rendering[i];
                if (!v.intervals || !v.total_ns) continue;
                buffer << "{\"type\":\"render_window\",\"tick_ms\":" << tick << ",\"swapchain_slot\":" << i
                    << ",\"intervals\":" << v.intervals << ",\"callback_rate_fps\":" << v.intervals * 1e9 / v.total_ns
                    << ",\"mean_interval_ms\":" << v.total_ns / 1e6 / v.intervals << ",\"max_interval_ms\":" << v.max_ns / 1e6
                    << ",\"meaning\":\"Engine render-present callback cadence, not proof of displayed frames.\"}\n";
            }
            if (const auto dropped = dropped_swapchains.exchange(0))
                buffer << "{\"type\":\"coverage\",\"sensor\":\"render\",\"status\":\"channel_capacity\",\"dropped\":" << dropped << "}\n";
            {
                std::lock_guard<std::mutex> lock(gpu_mutex);
                if (gpu_tick)
                    buffer << "{\"type\":\"gpu_budget\",\"tick_ms\":" << gpu_tick << ",\"hresult\":" << static_cast<long>(gpu_status)
                        << ",\"budget_bytes\":" << gpu_info.Budget << ",\"usage_bytes\":" << gpu_info.CurrentUsage
                        << ",\"meaning\":\"Process local-segment DXGI budget on adapter node zero; not all GPU allocations.\"}\n";
            }
            const auto ticks = server_ticks.exchange(0);
            const auto resets = game_resets.exchange(0);
            const auto window = tick - last_flush; last_flush = tick;
            buffer << "{\"type\":\"server_ticks\",\"tick_ms\":" << tick << ",\"window_ms\":" << window
                << ",\"ticks\":" << ticks << ",\"hz\":" << (window ? ticks * 1000.0 / window : 0)
                << ",\"game_time_ms\":" << last_game_time.load() << ",\"resets\":" << resets
                << ",\"meaning\":\"Distinct simulation times witnessed by the GSC frame coroutine, not network packet rate.\"}\n";
            for (std::size_t id = 0; id < snapshot.size(); ++id)
            {
                const auto& c = snapshot[id];
                if (!c.started && !c.calls && !c.failed_clock && !c.active) continue;
                const char* category = id >= 0x2100 ? "gsc_region" : id >= 0x1100 ? "gsc_method" : id >= 0x100 ? "gsc_function" : "engine_scope";
                const auto token = id >= 0x2100 ? id - 0x2100 : id >= 0x1100 ? id - 0x1100 + 0x8000 : id >= 0x100 ? id - 0x100 : id;
                buffer << "{\"type\":\"timing\",\"tick_ms\":" << tick << ",\"category\":\"" << category
                    << "\",\"id\":" << token << ",\"started\":" << c.started << ",\"calls\":" << c.calls
                    << ",\"total_us\":" << static_cast<double>(c.total_ns) / 1000.0
                    << ",\"max_us\":" << static_cast<double>(c.max_ns) / 1000.0
                    << ",\"failed_clock\":" << c.failed_clock << ",\"active\":" << c.active << "}\n";
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
    void render_frame(IDXGISwapChain* swap_chain) noexcept
    {
        if (!swap_chain || !enabled.load(std::memory_order_acquire)) return;
        try
        {
            if (!render_stats.record(reinterpret_cast<std::uintptr_t>(swap_chain), now_ns())) ++dropped_swapchains;
            // Query at most once per second on the renderer callback. COM
            // ownership stays local; no stale device pointer crosses threads.
            std::lock_guard<std::mutex> lock(gpu_mutex);
            const auto tick = GetTickCount64();
            if (tick - gpu_tick < 1000) return;
            gpu_tick = tick; gpu_info = {};
            Microsoft::WRL::ComPtr<IDXGIDevice> device;
            Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
            Microsoft::WRL::ComPtr<IDXGIAdapter3> adapter3;
            gpu_status = swap_chain->GetDevice(IID_PPV_ARGS(&device));
            if (SUCCEEDED(gpu_status)) gpu_status = device->GetAdapter(&adapter);
            if (SUCCEEDED(gpu_status)) gpu_status = adapter.As(&adapter3);
            if (SUCCEEDED(gpu_status)) gpu_status = adapter3->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &gpu_info);
        } catch (...) { }
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
    void begin_scope2(scope2_state& state) noexcept
    {
        if (!enabled.load(std::memory_order_acquire)) return;
        try
        {
            if (!stats.begin(2)) return;
            state.wall_open = true;
            state.wall_start = now_ns();
            if (scope2_cpu_enabled.load(std::memory_order_relaxed) && scope2_cpu.begin(state.cpu))
                scope2_cpu.attach_start(state.cpu, iw7::debugger::capture_current_thread_cpu());
        }
        catch (...) { ++scope2_cpu_internal_errors; }
    }
    void end_scope2(scope2_state& state) noexcept
    {
        if (!state.wall_open) return;
        state.wall_open = false;
        const auto wall_end = now_ns();
        // A captured start is finalized even if output/enabled changed meanwhile.
        if (state.cpu.pending())
        {
            try { scope2_cpu.end(state.cpu, iw7::debugger::capture_current_thread_cpu()); }
            catch (...) { ++scope2_cpu_internal_errors; }
        }
        try { stats.end(2, state.wall_start, wall_end); }
        catch (...) { ++scope2_cpu_internal_errors; }
    }
    class component final : public component_interface
    {
        void post_unpack() override
        {
            if (!utils::flags::has_flag("paris-debugger") || !utils::flags::has_flag("paris-isolated-lab")) return;
            scope2_cpu_enabled.store(utils::flags::has_flag("paris-debugger-thread-cpu"), std::memory_order_relaxed);
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
                if (id >= 0 && id < 256 && std::isfinite(token) && token >= 1.0f && token <= 600001.0f)
                    end(0x2100 + static_cast<std::size_t>(id), epoch_ + static_cast<std::uint64_t>((token - 1.0f) * 1000000.0f));
                return {};
            });
            gsc::function::add("paris_debug_tick", [](const gsc::function_args& args) -> scripting::script_value
            {
                if (!enabled.load(std::memory_order_acquire)) return {};
                const auto game_time = args[0].as<int>();
                const auto previous = last_game_time.exchange(game_time);
                if (game_time != previous) ++server_ticks;
                if (previous >= 0 && game_time < previous) ++game_resets;
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
                output.flush(); epoch_ = now_ns(); last_flush = GetTickCount64(); deadline = last_flush + 600000; enabled.store(true);
                if (scope2_cpu_enabled.load(std::memory_order_relaxed))
                {
                    output << "{\"type\":\"scope2_thread_cpu_config\",\"identity_capacity\":4,\"cpu_unit_ns\":100,\"cpu_resolution_ns\":null,\"wall_clock\":\"steady_clock.ns\",\"histogram_upper_ns\":[";
                    for (std::size_t i = 0; i < iw7::debugger::thread_cpu_histogram_ns.size(); ++i)
                        output << (i ? ",\"" : "\"") << std::to_string(iw7::debugger::thread_cpu_histogram_ns[i]) << '"';
                    output << "],\"histogram_final_bucket\":\"overflow\",\"ratio_interpretation\":\"Acquisition brackets only; CPU clock resolution unmeasured; never a rigorous majority bound.\"}\n";
                    output.flush();
                }
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
