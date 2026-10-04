#include "../../src/native/voice_transport.hpp"
#include <iostream>
#include <memory>
#include <random>

namespace t = voice::transport;
namespace w = voice::wire;
void require(bool value, const char* reason)
{
    if (!value)
        throw std::runtime_error(reason);
}
struct datagram
{
    int source, target;
    std::uint64_t due;
    std::string bytes;
};

int main()
{
    try
    {
        std::uint64_t next{1};
        t::random_source ids = [&] { return t::id{++next, 0x715}; };
        t::server server(ids);
        t::connections connections{};
        std::array<std::unique_ptr<t::client>, 4> clients;
        std::array<std::array<unsigned, 4>, 4> heard{};
        for (unsigned i = 0; i < clients.size(); ++i)
        {
            connections[i] = {i + 1, {i + 1, 123}, true};
            clients[i] = std::make_unique<t::client>(i + 1, ids);
        }
        std::mt19937 random(0x71504);
        std::vector<datagram> queue;
        std::uint64_t time{};
        std::size_t peak_queue{};
        unsigned lost{}, duplicate{}, refused{};
        auto enqueue = [&](int source, int target, const w::message& message) {
            const auto encoded = w::encode(message);
            require(!encoded.empty(), "simulation encoded invalid output");
            if (random() % 10 == 0)
            {
                ++lost;
                return;
            }
            queue.push_back({source, target, time + random() % 41, encoded});
            if (random() % 20 == 0)
            {
                queue.push_back({source, target, time + random() % 101, encoded});
                ++duplicate;
            }
            peak_queue = std::max(peak_queue, queue.size());
            require(queue.size() < 256, "unbounded simulated queue");
        };
        auto controls = [&](const std::vector<t::delivery>& output) {
            for (const auto& item : output)
            {
                require(item.slot < clients.size(), "unexpected target");
                if (item.data.type == w::kind::audio_down)
                    require(item.slot != item.data.slot, "server emitted self echo");
                enqueue(-1, static_cast<int>(item.slot), item.data);
            }
        };
        for (unsigned step = 0; step < 15000; ++step, time += 20)
        {
            // Five simulated minutes with four simultaneous 50-frame/s speakers.
            // Reconnect the same UID, reuse a slot with a different UID, then
            // restart the server while delayed datagrams remain queued.
            if (step == 2500)
            {
                connections[0].incarnation = {50, 50};
                clients[0]->reset();
            }
            if (step == 5000)
            {
                connections[1] = {10, {60, 60}, true};
                clients[1] = std::make_unique<t::client>(10, ids);
            }
            if (step == 7500)
                server.reset();
            controls(server.synchronize(connections, time));
            for (unsigned slot = 0; slot < clients.size(); ++slot)
            {
                for (const auto& message : clients[slot]->tick(time))
                    enqueue(static_cast<int>(slot), -1, message);
                if (clients[slot]->ready())
                    enqueue(static_cast<int>(slot), -1,
                            clients[slot]->audio("compressed native frame placeholder"));
            }
            // Delivery order is time-sorted, with random jitter and duplicates.
            // New downstream messages stay queued until their own due time.
            for (;;)
            {
                const auto candidate =
                    std::min_element(queue.begin(), queue.end(),
                                     [](const auto& a, const auto& b) { return a.due < b.due; });
                if (candidate == queue.end() || candidate->due > time)
                    break;
                const auto packet = *candidate;
                queue.erase(candidate);
                w::message decoded;
                require(w::decode(packet.bytes, decoded), "simulation wire decode");
                if (packet.target < 0)
                {
                    std::vector<t::delivery> output;
                    if (server.receive(static_cast<unsigned>(packet.source), decoded,
                                       static_cast<unsigned>(packet.bytes.size()), time, output))
                        controls(output);
                    else
                        ++refused;
                }
                else
                {
                    const auto received = clients[packet.target]->receive(
                        decoded, static_cast<unsigned>(packet.bytes.size()), time);
                    if (!received.accepted)
                        ++refused;
                    if (received.audio)
                        ++heard[packet.target][decoded.slot];
                }
            }
            if (step == 2000 || step == 4500 || step == 7000 || step == 14000)
                for (const auto& client : clients)
                    require(client->ready(), "loss/reconnect recovery did not converge");
        }
        unsigned total{};
        for (unsigned listener = 0; listener < clients.size(); ++listener)
            for (unsigned speaker = 0; speaker < clients.size(); ++speaker)
            {
                if (listener == speaker)
                    require(!heard[listener][speaker], "self audio accepted");
                else
                    require(heard[listener][speaker] > 3000,
                            "one direction did not sustain delivery");
                total += heard[listener][speaker];
            }
        std::cout << "PASS: 300 simulated seconds, four simultaneous speakers, 10% datagram loss, "
                     "0-40ms jitter, delayed duplicates, same-UID reconnect, different-UID slot "
                     "reuse and server restart; accepted_frames="
                  << total << " lost=" << lost << " duplicates=" << duplicate
                  << " rejected_stale_or_reordered=" << refused
                  << " peak_simulated_queue=" << peak_queue << ".\n";
        return 0;
    }
    catch (const std::exception& error)
    {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
