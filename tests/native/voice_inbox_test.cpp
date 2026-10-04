#include "../../src/native/voice_inbox.hpp"
#include <atomic>
#include <iostream>
#include <thread>

void require(bool value, const char* reason)
{
    if (!value)
        throw std::runtime_error(reason);
}

int main()
{
    try
    {
        voice::inbox inbox;
        voice::inbox::sources peers{};
        peers[0] = 0x7f0000010010;
        peers[1] = 0x7f0000010011; // Same IP, different port is a different sender.
        require(!inbox.push(peers[0], "data", 1), "unpublished source admitted");
        inbox.admit(peers, voice::inbox::server_capacity);
        for (unsigned i = 0; i < 150000; ++i)
            require(!inbox.push(0x010203040050, "data", 1), "outsider admitted");
        require(!inbox.push(0, "data", 1), "empty source admitted");
        require(!inbox.push(peers[0], {}, 1), "empty packet admitted");
        require(!inbox.push(peers[0], std::string(1201, 'x'), 1), "oversized packet admitted");
        for (unsigned i = 0; i < voice::inbox::server_capacity; ++i)
            require(inbox.push(peers[0], std::to_string(i), 100), "source capacity too small");
        require(!inbox.push(peers[0], "overflow", 100), "source capacity exceeded");
        require(inbox.push(peers[1], "other player", 100), "one sender starved another");
        unsigned expired{};
        auto packets = inbox.drain(100, expired);
        require(!expired && packets.size() == 33, "bounded fair drain size");
        require(packets[0].bytes == "0" && packets[1].bytes == "other player" &&
                    packets[2].bytes == "1" && packets.back().bytes == "31",
                "round-robin or sender order violated");
        require(inbox.push(peers[0], "departing", 100), "retirement setup");
        require(inbox.push(peers[1], "staying", 100), "retirement setup");
        const auto departed = peers[0];
        peers[0] = 123;
        inbox.admit(peers, voice::inbox::server_capacity);
        require(!inbox.push(departed, "late packet", 100), "retired source admitted");
        packets = inbox.drain(100, expired);
        require(packets.size() == 1 && packets[0].bytes == "staying", "retired queue retained");
        require(inbox.push(peers[0], "at boundary", 100), "age setup");
        packets = inbox.drain(600, expired);
        require(packets.size() == 1 && !expired, "exact age boundary rejected");
        require(inbox.push(peers[0], "too old", 100), "age setup");
        require(inbox.push(peers[0], "future", 602), "clock setup");
        require(inbox.drain(601, expired).empty() && expired == 2, "stale/future queue accepted");
        inbox.admit(peers, voice::inbox::client_capacity);
        for (unsigned i = 0; i < voice::inbox::client_capacity; ++i)
            require(inbox.push(peers[0], std::string(1200, 'x'), 700), "client capacity");
        require(!inbox.push(peers[0], "overflow", 700), "client capacity exceeded");
        inbox.admit({}, 0);
        require(inbox.drain(700, expired).empty(), "shutdown retained packets");

        // Exercise the actual callback/game-thread queue concurrently. Only
        // admitted, bounded packets may emerge; every accepted one is accounted.
        peers[0] = 1;
        peers[1] = 2;
        peers[2] = 3;
        peers[3] = 4;
        inbox.admit(peers, voice::inbox::server_capacity);
        std::atomic<unsigned> accepted{}, finished{};
        std::array<std::thread, 4> writers;
        for (unsigned slot = 0; slot < writers.size(); ++slot)
            writers[slot] = std::thread([&, slot] {
                for (unsigned i = 0; i < 25000; ++i)
                    if (inbox.push(peers[slot], "concurrent", 1000))
                        ++accepted;
                ++finished;
            });
        unsigned delivered{};
        bool valid = true;
        while (finished != writers.size())
        {
            packets = inbox.drain(1000, expired);
            valid = valid && packets.size() <= 4 * voice::inbox::server_capacity && !expired;
            for (const auto& packet : packets)
                valid = valid && packet.source >= 1 && packet.source <= 4 &&
                        packet.bytes == "concurrent";
            delivered += static_cast<unsigned>(packets.size());
            std::this_thread::yield();
        }
        for (auto& writer : writers)
            writer.join();
        delivered += static_cast<unsigned>(inbox.drain(1000, expired).size());
        require(valid && delivered == accepted, "concurrent queue corrupted or lost accepted packets");
        std::cout << "PASS: inbox admission, 150000 outsider packets, per-source isolation, "
                     "round-robin order, expiry, retirement, shutdown and 100000 concurrent attempts.\n";
        return 0;
    }
    catch (const std::exception& error)
    {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
