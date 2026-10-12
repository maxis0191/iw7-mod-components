#include <std_include.hpp>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "scheduler.hpp"
#include "console/console.hpp"
#include "paris_incident.hpp"
#include <utils/flags.hpp>
#include <fstream>
#include <deque>
#include <utils/hook.hpp>
#include <utils/cryptography.hpp>

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
        bool network_trace{};
        thread_local int packet_slot = -1;
        struct counters
        {
            std::atomic<unsigned> arrivals{}, raw_acks{}, negative_acks{}, backlog_gate{}, future_ack{}, moves{}, no_advance{}, texts{}, binaries{}, command_bytes{};
            std::atomic<int> raw_ack{}, max_pending{};
            std::atomic<std::uintptr_t> text_caller{}, binary_caller{};
            std::array<std::atomic<unsigned>, 256> opcodes{};
        };
        std::array<counters, 4> clients;
        utils::hook::detour packet_hook, move_hook, text_hook, binary_hook;

        int field(const void* client, std::size_t offset)
        {
            int value{};
            std::memcpy(&value, static_cast<const char*>(client) + offset, sizeof(value));
            return value;
        }
        int slot_of(const game::client_t* client)
        {
            // The engine publishes a table of pointers; do not assume a
            // contiguous allocation when attributing a diagnostic to a slot.
            const auto table = reinterpret_cast<game::client_t* const*>(0x146B22950);
            for (unsigned i = 0; i < std::min(*game::svs_numclients, 4u); ++i)
                if (table[i] == client) return static_cast<int>(i);
            return -1;
        }
        int pending(const game::client_t* client)
        {
            return static_cast<int>(static_cast<unsigned>(field(client, 0x41274)) - static_cast<unsigned>(field(client, 0x41278)));
        }
        void observe_command(game::client_t* client, const char* data, int size, bool binary, std::uintptr_t caller)
        {
            const int slot = slot_of(client);
            if (slot < 0) return;
            auto& c = clients[slot];
            if (binary) { ++c.binaries; c.binary_caller = caller; }
            else { ++c.texts; c.text_caller = caller; }
            if (data && size > 0) { ++c.opcodes[static_cast<unsigned char>(data[0])]; c.command_bytes += static_cast<unsigned>(size); }
            const int backlog = pending(client);
            auto maximum = c.max_pending.load();
            while (backlog > maximum && !c.max_pending.compare_exchange_weak(maximum, backlog)) {}
        }
        void text_stub(game::client_t* client, int type, const char* text)
        {
            const auto caller = reinterpret_cast<std::uintptr_t>(_ReturnAddress());
            text_hook.invoke<void>(client, type, text);
            observe_command(client, text, text ? static_cast<int>(strnlen_s(text, 1024)) : 0, false, caller);
        }
        void binary_stub(game::client_t* client, int type, game::msg_t* message)
        {
            const auto caller = reinterpret_cast<std::uintptr_t>(_ReturnAddress());
            binary_hook.invoke<void>(client, type, message);
            observe_command(client, message ? message->data : nullptr, message ? std::clamp(message->cursize, 0, 131072) : 0, true, caller);
        }
        void move_stub(game::client_t* client, game::msg_t* message, int delta)
        {
            const int slot = slot_of(client), before = field(client, 0x18);
            move_hook.invoke<void>(client, message, delta);
            if (slot >= 0) { ++clients[slot].moves; if (before == field(client, 0x18)) ++clients[slot].no_advance; }
        }
        void packet_stub(game::netadr_s* from, game::msg_t* message)
        {
            const int previous_slot = packet_slot;
            packet_slot = -1;
            const auto table = reinterpret_cast<game::client_t* const*>(0x146B22950);
            for (unsigned i = 0; i < std::min(*game::svs_numclients, 4u); ++i)
            {
                const auto* client = table[i];
                if (client && client->header.state >= 3 && from->type == client->remoteAddress.type &&
                    from->port == client->remoteAddress.port && !std::memcmp(from->ip, client->remoteAddress.ip, 4))
                { packet_slot = static_cast<int>(i); ++clients[i].arrivals; break; }
            }
            packet_hook.invoke<void>(from, message);
            packet_slot = previous_slot;
        }

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
                const int slot = slot_of(client);
                row += ",\"slot\":" + std::to_string(slot);
                if (slot >= 0) row += ",\"name\":" + quote(client->name, sizeof(client->name)) +
                    ",\"state\":" + std::to_string(client->header.state);
                if (slot >= 0 && network_trace) row += ",\"reliable_sequence\":" + std::to_string(field(client, 0x41274)) +
                    ",\"reliable_ack\":" + std::to_string(field(client, 0x41278)) + ",\"reliable_sent\":" + std::to_string(field(client, 0x4127C));
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
            static unsigned long long sampled{};
            if (!network_trace || now - sampled < 1000 || !game::SV_Loaded()) return;
            sampled = now;
            try
            {
                const auto table = reinterpret_cast<game::client_t* const*>(0x146B22950);
                const auto header = *reinterpret_cast<const char* const*>(0x146B22AC8);
                if (!header) return;
                const auto server_time = field(header, 0x1C);
                for (unsigned i = 0; i < std::min(*game::svs_numclients, 4u); ++i)
                {
                    const auto* client = table[i];
                    if (!client || client->header.state < 3) continue;
                    auto& c = clients[i];
                    const int seq = field(client, 0x41274), ack = field(client, 0x41278), backlog = pending(client);
                    auto row = base("reliable_window") + ",\"slot\":" + std::to_string(i) +
                        ",\"state\":" + std::to_string(client->header.state) + ",\"server_time\":" + std::to_string(server_time) +
                        ",\"sequence\":" + std::to_string(seq) + ",\"ack\":" + std::to_string(ack) +
                        ",\"sent\":" + std::to_string(field(client, 0x4127C)) + ",\"pending\":" + std::to_string(backlog) +
                        ",\"message_ack\":" + std::to_string(field(client, 0x41280)) +
                        ",\"last_packet_time\":" + std::to_string(field(client, 0x9EFB8)) +
                        ",\"last_usercmd_time\":" + std::to_string(field(client, 0x18)) +
                        ",\"arrivals\":" + std::to_string(c.arrivals.exchange(0)) +
                        ",\"raw_acks\":" + std::to_string(c.raw_acks.exchange(0)) +
                        ",\"negative_acks\":" + std::to_string(c.negative_acks.exchange(0)) +
                        ",\"ack_backlog_gate\":" + std::to_string(c.backlog_gate.exchange(0)) +
                        ",\"ack_ahead_of_sequence\":" + std::to_string(c.future_ack.exchange(0)) +
                        ",\"last_raw_ack\":" + std::to_string(c.raw_ack.load()) +
                        ",\"move_calls\":" + std::to_string(c.moves.exchange(0)) +
                        ",\"moves_without_immediate_advance\":" + std::to_string(c.no_advance.exchange(0)) +
                        ",\"text_calls\":" + std::to_string(c.texts.exchange(0)) +
                        ",\"binary_calls\":" + std::to_string(c.binaries.exchange(0)) +
                        ",\"requested_command_bytes\":" + std::to_string(c.command_bytes.exchange(0)) +
                        ",\"maximum_pending\":" + std::to_string(c.max_pending.exchange(0)) +
                        ",\"last_text_caller\":" + std::to_string(c.text_caller.load()) +
                        ",\"last_binary_caller\":" + std::to_string(c.binary_caller.load());
                    if (backlog > 0 && backlog <= 128)
                    {
                        const auto index = (static_cast<unsigned>(ack) + 1) & 127u;
                        row += ",\"oldest_pending_time\":" + std::to_string(field(client, 0x4C4 + index * 0x408));
                    }
                    if (client->header.state == 5 && client->gentity == &game::g_entities[i] && client->gentity->client)
                        row += ",\"ps_command_time\":" + std::to_string(client->gentity->client->ps.commandTime);
                    row += ",\"opcodes\":{";
                    bool first = true;
                    for (unsigned op = 0; op < 256; ++op)
                    {
                        const auto count = c.opcodes[op].exchange(0);
                        if (!count) continue;
                        if (!first) row += ',';
                        first = false;
                        row += '"' + std::to_string(op) + "\":" + std::to_string(count);
                    }
                    enqueue(row + "}}");
                }
            } catch (...) { ++lost; }
        }

        void install_network_trace()
        {
            // Candidate-only opt-in. Refuse an unknown/conflicting engine layout
            // before installing any hook; keep packet/queue/movement behavior.
            if (!utils::flags::has_flag("paris-isolated-lab") || !utils::flags::has_flag("paris-network-trace")) return;
            const std::pair<std::uintptr_t, const char*> signatures[] = {
                {0x140C583C0, "05545704DEE7906C4B85A25BCA4ED9744E17CB89B3F3A49F629001CF8ADE31BC"},
                {0x140C58610, "442A19659FE9096DE3A84E01A789D0005AB6710232EAA0A6A807AB732A813780"},
                {0x140C53520, "1DFF1076843D453425616C9557B8CFBB8515742805F68EAE3BE6E2411DEBF659"},
                {0x140C59330, "04BEF8FB7FD738C586552543F1F897F3813975423DD3052A2C1773B45A37BBBE"}};
            for (const auto& signature : signatures)
                if (_stricmp(utils::cryptography::sha256::compute(std::string(reinterpret_cast<const char*>(signature.first), 16), true).c_str(), signature.second) != 0)
                    throw std::runtime_error("Network trace engine signature mismatch");
            try
            {
                text_hook.create(0x140C583C0, text_stub);
                binary_hook.create(0x140C58610, binary_stub);
                move_hook.create(0x140C53520, move_stub);
                packet_hook.create(0x140C59330, packet_stub);
            }
            catch (...)
            {
                packet_hook.clear(); move_hook.clear(); binary_hook.clear(); text_hook.clear();
                throw;
            }
            network_trace = true;
            console::info("[Paris network trace] Ready; bounded queue, packet, ACK and movement observation.\n");
        }
    }

    void client_drop(const void* client, const char* reason, bool tell) noexcept
    {
        if (enabled.load(std::memory_order_relaxed)) record_drop(static_cast<const game::client_t*>(client), reason, tell);
    }

    void reliable_ack(std::int64_t value) noexcept
    {
        if (!network_trace || packet_slot < 0 || packet_slot >= 4) return;
        auto& c = clients[packet_slot];
        c.raw_ack = static_cast<int>(value); ++c.raw_acks;
        const bool negative = (static_cast<std::uint32_t>(value) & 0x80000000u) != 0;
        if (negative) ++c.negative_acks;
        const auto* client = reinterpret_cast<game::client_t* const*>(0x146B22950)[packet_slot];
        if (!client) return;
        // Mirror the existing guard and following native signed subtraction
        // for observation only. Return values and queue fields stay untouched.
        const auto sanitized = negative ? 0u : static_cast<unsigned>(value);
        const int difference = static_cast<int>(static_cast<unsigned>(field(client, 0x41274)) - sanitized);
        if (field(client, 0x41280) >= 0 && difference >= 128) ++c.backlog_gate;
        if (difference < 0) ++c.future_ack;
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
                install_network_trace();
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
