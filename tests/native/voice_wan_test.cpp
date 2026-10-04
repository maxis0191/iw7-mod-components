#include "../../src/native/voice_transport.hpp"
#include <iostream>
#include <memory>
#include <queue>
#include <random>

namespace t = voice::transport;
namespace w = voice::wire;
namespace
{
    void require(bool value, const char* reason)
    {
        if (!value)
            throw std::runtime_error(reason);
    }
    struct profile
    {
        const char* name;
        unsigned one_way_ms, jitter_ms, loss_percent, minimum_delivery_percent;
        unsigned receive_service_ms = 10;
    };
    struct datagram
    {
        int source, target;
        std::uint64_t due, arrival, order;
        std::string bytes;
    };
    struct later
    {
        bool operator()(const datagram& a, const datagram& b) const
        {
            if (a.due != b.due)
                return a.due > b.due;
            return a.arrival != b.arrival ? a.arrival > b.arrival : a.order > b.order;
        }
    };
    struct flow
    {
        unsigned delivered{}, maximum_gap_ms{}, maximum_delay_ms{};
        std::uint64_t last{};
    };
    // Score stable intervals separately from explicit recovery deadlines below.
    bool steady(std::uint64_t time)
    {
        return (time >= 10000 && time < 40000) || (time >= 70000 && time < 85000) ||
               (time >= 115000 && time < 130000) || (time >= 160000 && time < 175000) ||
               time >= 220000;
    }
    void simulate(const profile& link, unsigned seed)
    {
        std::uint64_t next_id{};
        t::random_source ids = [&] { return t::id{++next_id, 0x57414e}; };
        t::server server(ids);
        t::connections connections{};
        std::array<std::unique_ptr<t::client>, 4> clients;
        std::array<std::array<flow, 4>, 4> flows{};
        // The server and clients have independent GetTickCount64 boot clocks.
        constexpr std::array<std::uint64_t, 4> clocks{0, 123456, 86400000, 2592000000};
        constexpr std::uint64_t server_clock = 604800000;
        for (unsigned slot = 0; slot < clients.size(); ++slot)
        {
            connections[slot] = {slot + 1, {slot + 1, 1}, true};
            clients[slot] = std::make_unique<t::client>(slot + 1, ids);
        }
        std::priority_queue<datagram, std::vector<datagram>, later> queue;
        std::mt19937 random(seed);
        std::uint64_t time{}, order{};
        unsigned opportunities{}, lost{}, duplicates{}, rejected{}, peak_queue{};
        auto enqueue = [&](int source, int target, const w::message& message) {
            const auto bytes = w::encode(message);
            require(!bytes.empty(), "invalid simulated wire output");
            if ((time >= 180000 && time < 198000) || random() % 100 < link.loss_percent)
            {
                ++lost;
                return;
            }
            const auto delay = link.one_way_ms + random() % (link.jitter_ms + 1);
            auto schedule = [&](std::uint64_t arrival) {
                const auto due = (arrival + link.receive_service_ms - 1) /
                                 link.receive_service_ms * link.receive_service_ms;
                queue.push({source, target, due, arrival, ++order, bytes});
            };
            schedule(time + delay);
            if (random() % 20 == 0)
            {
                schedule(time + delay + 100);
                ++duplicates;
            }
            peak_queue = std::max(peak_queue, static_cast<unsigned>(queue.size()));
            require(queue.size() < 1024, "simulated network queue unbounded");
        };
        auto deliver = [&](const std::vector<t::delivery>& output) {
            for (const auto& item : output)
            {
                require(item.slot < clients.size(), "wrong simulated recipient");
                if (item.data.type == w::kind::audio_down)
                    require(item.slot != item.data.slot, "self echo emitted");
                enqueue(-1, static_cast<int>(item.slot), item.data);
            }
        };
        // A requested 10-ms scheduler interval is not a measured engine cadence.
        // Keep capture at 20 ms and model coarser receive service independently.
        for (; time < 240000; time += 10)
        {
            if (time == 45000)
            {
                connections[0].incarnation = {100, 2};
                clients[0]->reset();
            }
            if (time == 90000)
                server.reset();
            if (time == 135000)
            {
                connections[1] = {10, {101, 2}, true};
                clients[1] = std::make_unique<t::client>(10, ids);
            }
            deliver(server.synchronize(connections, server_clock + time));
            for (unsigned slot = 0; slot < clients.size(); ++slot)
            {
                for (const auto& message : clients[slot]->tick(clocks[slot] + time))
                    enqueue(static_cast<int>(slot), -1, message);
                if (time % 20 == 0 && clients[slot]->ready())
                    enqueue(static_cast<int>(slot), -1, clients[slot]->audio(std::to_string(time)));
            }
            if (steady(time) && time % 20 == 0)
                ++opportunities;
            if (!steady(time))
                for (auto& listener : flows)
                    for (auto& stream : listener)
                        stream.last = 0;
            while (!queue.empty() && queue.top().due <= time)
            {
                const auto packet = queue.top();
                queue.pop();
                w::message decoded;
                require(w::decode(packet.bytes, decoded), "simulated wire decode");
                if (packet.target < 0)
                {
                    std::vector<t::delivery> output;
                    if (server.receive(static_cast<unsigned>(packet.source), decoded,
                                       static_cast<unsigned>(packet.bytes.size()), server_clock + time,
                                       output))
                        deliver(output);
                    else
                        ++rejected;
                    continue;
                }
                const auto result = clients[packet.target]->receive(
                    decoded, static_cast<unsigned>(packet.bytes.size()), clocks[packet.target] + time);
                if (!result.accepted)
                    ++rejected;
                if (!result.audio)
                    continue;
                require(static_cast<unsigned>(packet.target) != decoded.slot, "self audio received");
                const auto& roster = clients[packet.target]->roster();
                require(roster.speakers[decoded.slot].generation == decoded.generation,
                        "audio attributed to a different generation");
                if (!steady(time))
                    continue;
                auto& stream = flows[packet.target][decoded.slot];
                ++stream.delivered;
                if (stream.last)
                    stream.maximum_gap_ms = std::max(stream.maximum_gap_ms,
                                                    static_cast<unsigned>(time - stream.last));
                stream.last = time;
                stream.maximum_delay_ms = std::max(
                    stream.maximum_delay_ms,
                    static_cast<unsigned>(time - std::stoull(decoded.frames.front())));
            }
            if (time == 10000 || time == 55000 || time == 110000 || time == 145000 || time == 218000)
                for (const auto& client : clients)
                    require(client->ready(), "handshake/reconnect/restart/outage recovery missed deadline");
        }
        unsigned minimum_delivery = 100, maximum_gap{}, maximum_delay{};
        for (unsigned listener = 0; listener < clients.size(); ++listener)
            for (unsigned speaker = 0; speaker < clients.size(); ++speaker)
            {
                if (listener == speaker)
                    continue;
                const auto& stream = flows[listener][speaker];
                const auto percentage = stream.delivered * 100 / opportunities;
                minimum_delivery = std::min(minimum_delivery, percentage);
                maximum_gap = std::max(maximum_gap, stream.maximum_gap_ms);
                maximum_delay = std::max(maximum_delay, stream.maximum_delay_ms);
                if (percentage < link.minimum_delivery_percent || stream.maximum_gap_ms > 1000)
                    std::cerr << link.name << " direction=" << speaker << "->" << listener
                              << " delivered=" << stream.delivered << "/" << opportunities
                              << " percent=" << percentage << " gap=" << stream.maximum_gap_ms
                              << " delay=" << stream.maximum_delay_ms << '\n';
                require(percentage >= link.minimum_delivery_percent, "one direction lost excessive frames");
                require(stream.maximum_gap_ms <= 1000, "steady flow stalled for over a second");
                require(stream.maximum_delay_ms <= 2 * (link.one_way_ms + link.jitter_ms + 20) + 200,
                        "stale audio accumulated latency");
            }
        std::cout << "PASS: WAN " << link.name << " seed=" << seed
                  << " 240s, four speakers, independent clocks, reconnect/reuse/restart/18s outage; "
                  << "minimum_direction_delivery_percent=" << minimum_delivery
                  << " maximum_steady_gap_ms=" << maximum_gap
                  << " maximum_transport_delay_ms=" << maximum_delay << " lost=" << lost
                  << " duplicates=" << duplicates << " rejected=" << rejected
                  << " peak_queue=" << peak_queue << ".\n";
    }
}
int main()
{
    try
    {
        for (const auto seed : {0x57414e01u, 0x57414e02u, 0x57414e03u})
        {
            simulate({"clean", 10, 0, 0, 99}, seed);
            simulate({"transatlantic", 90, 20, 2, 90}, seed);
            simulate({"transatlantic-service20", 90, 20, 2, 80, 20}, seed);
            // Liveness under severe reordering, not a speech-quality target:
            // the low-latency transport deliberately discards backward frames.
            simulate({"adverse", 120, 80, 10, 40}, seed);
        }
        return 0;
    }
    catch (const std::exception& error)
    {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
