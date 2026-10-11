#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "scheduler.hpp"
#include "console/console.hpp"
#include "paris_incident.hpp"
#include <utils/flags.hpp>
#include <fstream>
#include <deque>

namespace paris_incident
{
    namespace
    {
        std::atomic<bool> enabled{false};
        std::atomic<unsigned long long> lost{0}, packets{0}, packet_bytes{0}, send_errors{0};
        std::atomic<unsigned long long> frames{0}, max_gap{0};
        std::mutex queue_mutex;
        std::mutex writer_mutex;
        std::deque<std::string> queue;
        std::ofstream output;
        std::filesystem::path directory;
        std::string stem;
        unsigned part{};
        std::size_t bytes{};

        std::string utc()
        {
            SYSTEMTIME t{}; GetSystemTime(&t);
            char result[40]{};
            sprintf_s(result, "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ",
                t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
            return result;
        }
        std::string quote(const char* value, std::size_t limit)
        {
            std::string result = "\"";
            if (value) for (std::size_t i = 0; i < limit && value[i]; ++i)
            {
                const auto byte_value = static_cast<unsigned char>(value[i]);
                if (byte_value == '"' || byte_value == '\\') { result += '\\'; result += static_cast<char>(byte_value); }
                else if (byte_value >= 32 && byte_value < 127) result += static_cast<char>(byte_value);
                else { char escape[8]{}; sprintf_s(escape, "\\u%04x", static_cast<unsigned>(byte_value)); result += escape; }
            }
            return result + '"';
        }
        std::string base(const char* type)
        {
            return "{\"schema\":\"iw7.incident.native/1\",\"type\":\"" + std::string(type) +
                "\",\"utc\":\"" + utc() + "\",\"tick_ms\":" + std::to_string(GetTickCount64()) +
                ",\"pid\":" + std::to_string(GetCurrentProcessId()) +
                ",\"thread\":" + std::to_string(GetCurrentThreadId());
        }
        std::string stack()
        {
            void* callers[8]{};
            const auto count = CaptureStackBackTrace(2, 8, callers, nullptr);
            std::string text = ",\"callers\":[";
            for (USHORT i = 0; i < count; ++i)
            {
                if (i) text += ',';
                text += std::to_string(reinterpret_cast<std::uintptr_t>(callers[i]));
            }
            return text + ']';
        }
        void enqueue(std::string row)
        {
            std::unique_lock<std::mutex> lock(queue_mutex, std::try_to_lock);
            if (!lock || queue.size() >= 256) { ++lost; return; }
            queue.push_back(std::move(row));
        }
        void open_part()
        {
            output.close();
            const auto path = directory / (stem + "-" + std::to_string(part++ % 8) + ".jsonl");
            output.open(path, std::ios::binary | std::ios::trunc);
            bytes = 0;
            if (!output) throw std::runtime_error("Incident output could not be opened");
            output << base("segment") << ",\"part\":" << part
                << ",\"meaning\":\"8 rotating 8MiB native segments per process; external recorder retains timeline.\"}\n";
        }
        void flush()
        {
            if (!enabled.load(std::memory_order_relaxed)) return;
            std::lock_guard<std::mutex> writer_lock(writer_mutex);
            if (!enabled.load(std::memory_order_relaxed)) return;
            try
            {
                std::deque<std::string> batch;
                { std::lock_guard<std::mutex> lock(queue_mutex); queue.swap(batch); }
                batch.push_back(base("health") + ",\"events_lost\":" + std::to_string(lost.exchange(0)) +
                    ",\"packets\":" + std::to_string(packets.exchange(0)) +
                    ",\"packet_bytes\":" + std::to_string(packet_bytes.exchange(0)) +
                    ",\"send_errors\":" + std::to_string(send_errors.exchange(0)) +
                    ",\"server_callbacks\":" + std::to_string(frames.exchange(0)) +
                    ",\"max_callback_gap_ms\":" + std::to_string(max_gap.exchange(0)) + "}");
                for (const auto& row : batch)
                {
                    if (bytes + row.size() + 1 > 8 * 1024 * 1024) open_part();
                    output << row << '\n'; bytes += row.size() + 1;
                }
                output.flush();
                if (!output) throw std::runtime_error("Incident output write failed");
            }
            catch (...) { enabled.store(false); console::warn("[Paris incident] Recorder output failed; coverage unavailable.\n"); }
        }
        void record_drop(const game::client_t* client, const char* reason, bool tell)
        {
            // Capture before native cleanup destroys the session identity.
            const auto error = WSAGetLastError();
            if (enabled.load(std::memory_order_relaxed)) try
            {
                auto row = base("client_drop") + ",\"reason\":" + quote(reason, 192) +
                    ",\"tell_client\":" + (tell ? "true" : "false");
                const auto* clients = *game::svs_clients;
                int slot = -1;
                if (clients) for (unsigned i = 0; i < std::min(*game::svs_numclients, 4u); ++i)
                    if (&clients[i] == client) { slot = static_cast<int>(i); break; }
                row += ",\"slot\":" + std::to_string(slot);
                if (slot >= 0) row += ",\"name\":" + quote(client->name, sizeof(client->name)) +
                    ",\"state\":" + std::to_string(client->header.state);
                enqueue(row + stack() + "}");
            } catch (...) { ++lost; }
            WSASetLastError(error);
        }
        void server_tick()
        {
            static unsigned long long previous{};
            const auto now = GetTickCount64();
            if (previous && now >= previous)
            {
                auto current = max_gap.load(std::memory_order_relaxed);
                while (now - previous > current && !max_gap.compare_exchange_weak(current, now - previous)) {}
            }
            previous = now; ++frames;
        }
    }

    void client_drop(const void* client, const char* reason, bool tell) noexcept
    {
        if (enabled.load(std::memory_order_relaxed)) record_drop(static_cast<const game::client_t*>(client), reason, tell);
    }

    void send_result(int length, int result, int error, const void* address) noexcept
    {
        if (!enabled.load(std::memory_order_relaxed)) return;
        ++packets;
        if (result >= 0) packet_bytes += static_cast<unsigned>(result);
        else if (result == SOCKET_ERROR)
        {
            ++send_errors;
            try
            {
                const auto* peer = static_cast<const sockaddr*>(address);
                auto row = base("udp_send_error") + ",\"winsock_error\":" + std::to_string(error) +
                    ",\"length\":" + std::to_string(length) + ",\"family\":" + std::to_string(peer ? peer->sa_family : 0);
                if (peer && peer->sa_family == AF_INET)
                {
                    const auto* ip = reinterpret_cast<const sockaddr_in*>(peer);
                    const auto* b = reinterpret_cast<const unsigned char*>(&ip->sin_addr);
                    row += ",\"peer\":\"" + std::to_string(b[0]) + "." + std::to_string(b[1]) + "." +
                        std::to_string(b[2]) + "." + std::to_string(b[3]) + "\",\"port\":" + std::to_string(ntohs(ip->sin_port));
                }
                enqueue(row + stack() + "}");
            } catch (...) { ++lost; }
        }
    }

    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            if (!game::environment::is_dedi() || !utils::flags::has_flag("paris-incident-log")) return;
            try
            {
                directory = "iw7-mod/logs/incidents";
                std::filesystem::create_directories(directory);
                stem = "native-" + std::to_string(GetCurrentProcessId()) + "-" + std::to_string(GetTickCount64());
                open_part();
                enabled.store(true);
                scheduler::loop(server_tick, scheduler::server, 0ms);
                scheduler::loop(flush, scheduler::async, 1s);
                enqueue(base("startup") + ",\"upstream_drop_observer\":true,\"send_hook\":true,\"protocol_changed\":false}");
                console::info("[Paris incident] Ready; native drop reasons, UDP errors and server cadence.\n");
            }
            catch (...) { enabled.store(false); console::warn("[Paris incident] Startup refused; coverage unavailable.\n"); }
        }
        void pre_destroy() override
        {
            if (enabled.load()) { enqueue(base("shutdown") + "}"); flush(); }
            enabled.store(false);
        }
    };
}
REGISTER_COMPONENT(paris_incident::component)
