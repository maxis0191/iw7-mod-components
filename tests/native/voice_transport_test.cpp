#include "../../src/native/voice_transport.hpp"
#include <iostream>
#include <random>

namespace w = voice::wire;
namespace t = voice::transport;
namespace s = voice::state;
void require(bool value, const char* reason)
{
    if (!value)
        throw std::runtime_error(reason);
}
w::message roundtrip(const w::message& value)
{
    const auto bytes = w::encode(value);
    w::message result;
    require(!bytes.empty() && w::decode(bytes, result), "wire roundtrip");
    return result;
}
struct fixture
{
    std::uint64_t next{100};
    t::random_source rng = [this] { return t::id{++next, 123}; };
    t::server server{rng};
    t::client a{1, rng}, b{2, rng};
    t::connections connections{};
    std::uint64_t time{1000};
    fixture()
    {
        connections[0] = {1, {1, 1}, true};
        connections[1] = {2, {2, 2}, true};
        server.synchronize(connections, time);
    }
    std::vector<t::delivery> up(unsigned slot, const w::message& value)
    {
        std::vector<t::delivery> result;
        require(server.receive(slot, roundtrip(value),
                               static_cast<unsigned>(w::encode(value).size()), time, result),
                "server refused valid input");
        return result;
    }
    t::received down(t::client& client, const w::message& value)
    {
        return client.receive(roundtrip(value), static_cast<unsigned>(w::encode(value).size()),
                              time);
    }
    void deliver(const std::vector<t::delivery>& messages)
    {
        for (const auto& item : messages)
            require(down(item.slot == 0 ? a : b, item.data).accepted,
                    "client refused valid control/audio");
    }
    void join(unsigned slot, t::client& client)
    {
        time += 1000;
        const auto hello = client.tick(time);
        require(hello.size() == 1, "missing hello");
        auto challenge = up(slot, hello[0]);
        require(challenge.size() == 1 && down(client, challenge[0].data).accepted, "challenge");
        time += 20;
        const auto confirm = client.tick(time);
        require(confirm.size() == 1, "missing confirm");
        deliver(up(slot, confirm[0]));
        require(client.ready(), "missing welcome");
    }
};

int main()
{
    try
    {
        fixture f;
        f.join(0, f.a);
        f.join(1, f.b);
        // Audio directions, no self echo, duplicates and reordered old data.
        auto first = f.up(0, f.a.audio("frame"));
        require(first.size() == 1 && first[0].slot == 1, "audio recipient");
        require(f.down(f.b, first[0].data).audio, "A to B audio");
        require(!f.down(f.b, first[0].data).accepted, "duplicate audio");
        auto second = f.up(0, f.a.audio("newer"));
        auto third = f.up(0, f.a.audio("newest"));
        require(f.down(f.b, third[0].data).audio && !f.down(f.b, second[0].data).accepted,
                "reordered audio");
        auto reverse = f.up(1, f.b.audio("reverse"));
        require(f.down(f.a, reverse[0].data).audio, "B to A audio");
        const auto old_audio = first[0].data;
        const auto old_roster = f.b.roster();

        // Same UID and endpoint reconnect still has a new accepted-game incarnation.
        f.connections[0].incarnation = {9, 9};
        f.deliver(f.server.synchronize(f.connections, ++f.time));
        require(!f.down(f.b, old_audio).accepted, "disconnected generation audio");
        f.a.reset();
        f.join(0, f.a);
        auto reconnected = f.up(0, f.a.audio("reconnected"));
        require(f.down(f.b, reconnected[0].data).audio, "surviving listener silenced reconnect");
        require(!f.down(f.b, old_audio).accepted, "delayed prior generation audio");
        w::message stale;
        stale.type = w::kind::roster;
        stale.server = old_roster.server;
        stale.recipient = old_roster.listener;
        stale.slot = 1;
        stale.members = old_roster;
        require(!f.down(f.b, stale).accepted, "stale roster rollback");
        require(!f.down(f.b, reconnected[0].data).accepted, "old control reset replay");

        // Retired hello cannot rotate the current capability, and its old confirm
        // cannot authorize a new generation without the newly issued challenge.
        const auto current_generation = f.b.roster().speakers[0].generation;
        w::message retired;
        retired.type = w::kind::hello;
        retired.nonce = {20, 20};
        auto delayed_challenge = f.up(0, retired);
        w::message guessed;
        guessed.type = w::kind::confirm;
        guessed.server = f.server.epoch();
        guessed.nonce = retired.nonce;
        guessed.challenge = {21, 21};
        std::vector<t::delivery> rejected;
        require(!f.server.receive(0, guessed, 52, f.time, rejected),
                "old/guessed confirm accepted");
        auto uninterrupted = f.up(0, f.a.audio("still live"));
        require(uninterrupted[0].data.generation == current_generation &&
                    f.down(f.b, uninterrupted[0].data).audio,
                "hello changed active generation");
        require(!f.down(f.a, delayed_challenge[0].data).accepted,
                "active client adopted retired challenge");

        // Duplicate confirm resends a welcome, without rotating/resetting streams.
        fixture duplicate;
        auto hello = duplicate.a.tick(duplicate.time);
        auto challenge = duplicate.up(0, hello[0]);
        require(duplicate.down(duplicate.a, challenge[0].data).accepted, "duplicate setup");
        auto confirm = duplicate.a.tick(duplicate.time)[0];
        duplicate.deliver(duplicate.up(0, confirm));
        const auto generation = duplicate.a.roster().speakers[0].generation;
        duplicate.deliver(duplicate.up(0, confirm));
        require(duplicate.a.roster().speakers[0].generation == generation,
                "duplicate confirm rotated generation");

        // Lost challenge/welcome and expired challenge recover by retry/new nonce.
        fixture loss;
        auto lost_hello = loss.a.tick(loss.time)[0];
        loss.up(0, lost_hello); // drop challenge
        loss.time += 500;
        auto retry = loss.up(0, loss.a.tick(loss.time)[0]);
        require(loss.down(loss.a, retry[0].data).accepted, "lost challenge retry");
        auto lost_confirm = loss.a.tick(loss.time)[0];
        loss.up(0, lost_confirm); // drop welcome
        loss.time += 500;
        loss.deliver(loss.up(0, loss.a.tick(loss.time)[0]));
        require(loss.a.ready(), "lost welcome retry");
        fixture expiry;
        auto expiring_hello = expiry.a.tick(expiry.time)[0];
        auto expiring = expiry.up(0, expiring_hello);
        require(expiry.down(expiry.a, expiring[0].data).accepted, "expiry setup");
        expiry.time += t::challenge_ms + 1;
        const auto restarted = expiry.a.tick(expiry.time)[0];
        require(restarted.type == w::kind::hello && restarted.nonce != expiring_hello.nonce,
                "expired handshake did not restart");
        require(!expiry.down(expiry.a, expiring[0].data).accepted,
                "old challenge adopted after handshake reset");

        // Slot reuse, server restart and listener lease all reject prior traffic.
        f.connections[0] = {3, {30, 30}, true};
        f.deliver(f.server.synchronize(f.connections, ++f.time));
        require(!f.down(f.b, reconnected[0].data).accepted, "old slot occupant audio");
        f.server.reset();
        f.server.synchronize(f.connections, ++f.time);
        const auto old_server_audio = f.b.audio("old server");
        require(!f.server.receive(1, old_server_audio,
                                  static_cast<unsigned>(w::encode(old_server_audio).size()), f.time,
                                  rejected),
                "old server capability");
        const auto heartbeat = f.b.tick(f.time + t::lease_ms + 1);
        require(!f.b.ready() && heartbeat[0].type == w::kind::hello,
                "listener lease did not reset");
        require(!f.down(f.b, reconnected[0].data).accepted, "audio after listener reset");
        require(!f.server.receive(s::max_speakers, retired, 20, f.time, rejected),
                "out-of-range source");
        f.connections = {};
        f.server.synchronize(f.connections, ++f.time);
        require(!f.server.receive(0, retired, 20, f.time, rejected), "unconnected source");

        // Byte parser: every truncation/trailing byte, unknown versions/kinds,
        // oversized payload and seeded random mutation. Failure is atomic.
        fixture parser;
        parser.join(0, parser.a);
        parser.join(1, parser.b);
        const auto roster = parser.up(0, parser.a.tick(parser.time + 1000)[0])[0].data;
        const auto welcome = duplicate.up(0, confirm)[0].data;
        const std::vector<w::message> corpus{expiring_hello,
                                             expiring[0].data,
                                             lost_confirm,
                                             welcome,
                                             roster,
                                             parser.a.tick(parser.time + 2000)[0],
                                             parser.a.audio("compressed"),
                                             parser.up(0, parser.a.audio("downstream"))[0].data};
        for (const auto& sample : corpus)
        {
            const auto encoded = w::encode(sample);
            require(!encoded.empty(), "empty corpus");
            w::message decoded;
            for (std::size_t size = 0; size < encoded.size(); ++size)
                require(!w::decode(std::string_view(encoded).substr(0, size), decoded) &&
                            decoded.frames.empty(),
                        "truncated packet published state");
            require(!w::decode(encoded + "x", decoded), "trailing byte");
            auto bad = encoded;
            bad[2] = 99;
            require(!w::decode(bad, decoded), "unknown version");
            bad = encoded;
            bad[3] = 99;
            require(!w::decode(bad, decoded), "unknown kind");
        }
        w::message decoded;
        require(!w::decode(std::string(w::max_packet_bytes + 1, 'x'), decoded), "oversize");
        auto limits = parser.a.audio(std::string(w::max_frame_bytes, 'x'));
        require(!w::encode(limits).empty(), "maximum frame rejected");
        limits.frames[0].push_back('x');
        require(w::encode(limits).empty(), "oversized frame accepted");
        limits.frames = std::vector<std::string>(w::max_frames, "x");
        require(!w::encode(limits).empty(), "maximum frame count rejected");
        limits.frames.push_back("x");
        require(w::encode(limits).empty(), "excess frame count accepted");
        limits.frames = std::vector<std::string>(5, std::string(w::max_frame_bytes, 'x'));
        require(w::encode(limits).empty(), "oversized combined frames accepted");
        limits.frames = {""};
        require(w::encode(limits).empty(), "empty frame accepted");
        auto invalid_roster = roster;
        invalid_roster.members.speakers[2] = invalid_roster.members.speakers[0];
        require(w::encode(invalid_roster).empty(), "duplicate roster identity encoded");
        require(!parser.server.receive(0, limits, 1, parser.time, rejected),
                "typed invalid audio bypassed parser");
        require(!parser.b.receive(corpus.back(), 1, parser.time).accepted,
                "typed invalid byte count bypassed bounds");
        std::mt19937 random(0x71502);
        for (unsigned i = 0; i < 200000; ++i)
        {
            std::string data;
            if (i % 2)
                data = w::encode(corpus[random() % corpus.size()]);
            else
                data.resize(random() % 1300);
            for (unsigned change = 0; change < 1 + random() % 12; ++change)
                if (!data.empty())
                    data[random() % data.size()] = static_cast<char>(random());
            if (w::decode(data, decoded))
                require(w::encode(decoded) == data, "noncanonical fuzz acceptance");
            else
                require(decoded.frames.empty() && decoded.server.empty(),
                        "failed decode leaked partial state");
        }
        t::budget rate(2, 1);
        require(rate.accept(1, 100) && rate.accept(1, 100) && !rate.accept(1, 100),
                "rate capacity");
        require(!rate.accept(1, 99) && rate.accept(1, 1100), "rate time/refill");
        std::cout << "PASS: v2 handshake loss/replay/expiry, bidirectional audio, speaker/listener "
                     "reconnect, slot/server reset, bounded wire and 200000 seeded mutations.\n";
        return 0;
    }
    catch (const std::exception& error)
    {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
