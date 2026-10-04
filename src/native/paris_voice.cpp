#include <std_include.hpp>
#include <cstdlib>
#include "loader/component_loader.hpp"
#include "game/game.hpp"
#include "network.hpp"
#include "party.hpp"
#include "scheduler.hpp"
#include "scripting.hpp"
#include "command.hpp"
#include "console/console.hpp"
#include <utils/hook.hpp>
#include <utils/cryptography.hpp>
#include <utils/flags.hpp>
#include <utils/info_string.hpp>
#include <cmath>
#include <charconv>
#include "paris_voice_protocol.hpp"
#include "paris_test_safety.hpp"
#include "voice_relay.hpp"

namespace paris_voice
{
    namespace
    {
        // Config "set" may create a string dvar. Read only the union member
        // matching its type, so string "0" cannot be mistaken for its pointer.
        bool read_module_enabled(const game::dvar_t* setting)
        {
            if (!setting) return true;
            switch (setting->type)
            {
            case game::DVAR_TYPE_BOOL: return setting->current.enabled;
            case game::DVAR_TYPE_INT: return setting->current.integer != 0;
            case game::DVAR_TYPE_STRING:
            {
                const auto* text = setting->current.string;
                if (!text) return false;
                char* end = nullptr;
                const auto value = std::strtol(text, &end, 10);
                return end != text && *end == '\0' && value != 0;
            }
            default: return false;
            }
        }

        bool module_enabled()
        {
            const auto* setting = game::Dvar_FindVar("paris_mod_voice");
            const bool enabled = read_module_enabled(setting);
            static int previous = -1;
            if (previous != static_cast<int>(enabled))
            {
                previous = static_cast<int>(enabled);
                console::info("[paris-voice] Module enabled=%d; dvar_type=%u.\n",
                    previous, setting ? static_cast<unsigned>(setting->type) : 255u);
            }
            return enabled;
        }

        namespace wire = protocol;

        constexpr const char* transport = "parisvoice";
        constexpr std::uint64_t timeout_ms = 15000;
        constexpr std::size_t inbox_limit = 128;
        utils::hook::detour queue_voice_hook;
        utils::hook::detour decode_voice_hook;
        utils::hook::detour enqueue_voice_hook;
        utils::hook::detour capture_voice_hook;
        utils::hook::detour encode_voice_hook;
        utils::hook::detour native_batch_hook, native_receive_hook, native_send_hook;
        bool native_trace{}, relay_witness{};
        bool native_audio_test()
        {
            return (utils::flags::has_flag("paris-isolated-lab") && utils::flags::has_flag("paris-voice-audio-lab")) ||
                (utils::flags::has_flag("paris-voice-base-test") &&
                    utils::flags::has_flag(game::environment::is_dedi() ? "paris-server-test" : "paris-server-client-test"));
        }
        std::atomic<std::uint64_t> native_encoded{}, native_batches{}, native_packets{}, native_send_ok{}, native_received{};

        void native_batch(int local_client)
        {
            ++native_batches;
            native_batch_hook.invoke<void>(local_client);
        }
        void native_receive(int local_client, game::msg_t* message)
        {
            ++native_received;
            native_receive_hook.invoke<void>(local_client, message);
        }
        bool native_send(game::SessionData* session, int local_client, int channel, int recipient,
            game::msg_t* message, bool reliable)
        {
            ++native_packets;
            const auto result = native_send_hook.invoke<bool>(session, local_client, channel, recipient, message, reliable);
            if (result) ++native_send_ok;
            return result;
        }
        bool trace_signatures_match()
        {
            struct signature { std::uintptr_t address; const char* bytes; std::size_t size; };
            // Exact retail entry bytes from the local post-unpack reference. Check
            // every entry before installing any trace hook; no executable dump in Git.
            const signature entries[] = {
                {0x14037D960, "\x40\x53\x48\x83\xec\x20\x48\x63\xd9\x85\xc9", 11},
                {0x140B79310, "\x48\x89\x5c\x24\x20\x57\xb8\x30\x40\x00\x00", 11},
                {0x140B79B60, "\x48\x89\x5c\x24\x10\x56\x48\x83\xec\x60", 10},
                {0x140B79D30, "\x40\x57\x41\x57\xb8\x48\x20\x00\x00", 9},
                {0x14037D5C0, "\x41\x54\x48\x81\xec\x00\x09\x00\x00", 9},
                {0x14037CFF0, "\x40\x53\x41\x54\x41\x55\x48\x81\xec\xc0\x09\x00\x00", 13},
                {0x14037BFF0, "\x40\x53\x56\x57\x48\x81\xec\xa0\x08\x00\x00", 11},
                {0x140B794F0, "\x48\x89\x5c\x24\x08\x48\x89\x74\x24\x10\x57\x48\x83\xec\x20", 15},
                {0x1405E9520, "\x48\x8b\x01\x48\xff\x60\x50", 7},
            };
            for (const auto& entry : entries)
                if (std::memcmp(reinterpret_cast<const void*>(entry.address), entry.bytes, entry.size) != 0)
                    return false;
            return true;
        }
        std::mutex inbox_mutex, state_mutex;
        struct incoming { game::netadr_s from; wire::packet data; std::uint64_t time; unsigned bytes; };
        std::vector<incoming> inbox;
        struct counters
        {
            std::atomic<std::uint64_t> captured{}, sent{}, relayed{}, decoded{}, pcm_bytes{}, rejected{}, muted{};
            std::atomic<std::uint64_t> queued_bytes{}, queue_errors{};
            std::atomic<std::uint64_t> capture_blocks{};
            std::atomic<double> decoded_peak_rms{}, decoded_peak_tone_ratio{};
            std::atomic<std::uint64_t> decoded_target_frames{};
            std::atomic<std::uint64_t> encoded_bytes{}, tiny_encoded_frames{};
        } stats;
        struct server_peer
        {
            game::netadr_s address{};
            std::string identity;
            std::uint64_t token{}, challenge{}, seen{}, hello_time{};
            wire::replay_window replay;
            wire::rate_limit rate;
        };
        std::array<server_peer, wire::slots> peers{};
        struct client_state
        {
            game::netadr_s host{};
            bool connected{};
            std::uint64_t token{}, challenge{}, last_hello{}, last_ready{};
            std::uint32_t sequence{};
            unsigned char own_slot{};
            std::array<wire::replay_window, wire::slots> replay{};
            std::array<wire::rate_limit, wire::slots> rate{};
        } client;
        bool local_test_probed{};
        bool local_test_connected{};
        bool local_test_gates{};
        int relay_test_frame{};
        std::uint64_t relay_test_begin{};

        std::uint64_t now() { return GetTickCount64(); }
        std::uint64_t random_token()
        {
            std::uint64_t value{};
            do { utils::cryptography::random::get_data(&value, sizeof(value)); } while (!value);
            return value;
        }
        bool zombies() { return game::Com_GameMode_GetActiveGameMode() == game::GAME_MODE_CP; }
        bool enabled()
        {
            const auto* dvar = game::Dvar_FindVar("cl_voice");
            return dvar && dvar->current.enabled;
        }
        bool audio_initialized() { return *reinterpret_cast<const int*>(0x1477A012C) != 0; }
        int decode_voice(const char* data, int length, short* pcm, int samples)
        {
            const int result = decode_voice_hook.invoke<int>(data, length, pcm, samples);
            if (result > 0) { ++stats.decoded; stats.pcm_bytes += result; }
            if ((relay_witness || utils::flags::has_flag("iw7-voice-relay")) && pcm && result > 0 && result <= 16384 && result % 2 == 0)
            {
                const int count = result / 2;
                double power{}, re{}, im{};
                for (int i = 0; i < count; ++i)
                {
                    const double sample = pcm[i] / 32768.0;
                    const double phase = 6.283185307179586 * 997 * i / 8000.0;
                    power += sample * sample;
                    re += sample * std::cos(phase); im += sample * std::sin(phase);
                }
                const double rms = std::sqrt(power / count);
                const double ratio = power > 0 ? 2 * (re * re + im * im) / (count * power) : 0;
                if (rms > 0.01 && ratio > 0.4) ++stats.decoded_target_frames;
                auto prior = stats.decoded_peak_rms.load();
                while (rms > prior && !stats.decoded_peak_rms.compare_exchange_weak(prior, rms)) {}
                prior = stats.decoded_peak_tone_ratio.load();
                while (ratio > prior && !stats.decoded_peak_tone_ratio.compare_exchange_weak(prior, ratio)) {}
            }
            return result;
        }
        int enqueue_voice(void* buffer, const short* pcm, int bytes)
        {
            const int result = enqueue_voice_hook.invoke<int>(buffer, pcm, bytes);
            if (result > 0) stats.queued_bytes += result;
            else if (result < 0) ++stats.queue_errors;
            return result;
        }
        std::atomic<bool> probe_running{};
        std::atomic<std::uint64_t> probe_device_blocks{};
        struct capture_buffer
        {
            short* pcm;
            int bytes, samples, sample_bytes;
            int reserved[3];
            int consumed;
        };
        static_assert(sizeof(capture_buffer) == 40 && offsetof(capture_buffer, consumed) == 32);
        int capture_voice(void* buffer)
        {
            ++stats.capture_blocks;
            if (probe_running)
            {
                // The opt-in post-device stimulus replaces hardware input only
                // while active. Mark its samples consumed rather than retaining
                // microphone backlog or doubling the native 50-Hz frame stream.
                auto* input = static_cast<capture_buffer*>(buffer);
                if (input && input->samples >= 0 && input->samples <= 65536 &&
                    input->sample_bytes == 2 && input->bytes == input->samples * 2)
                    input->consumed = input->samples;
                ++probe_device_blocks;
                return 0;
            }
            return capture_voice_hook.invoke<int>(buffer);
        }
        int encode_voice(const short* pcm, char* data, int capacity)
        {
            const int size = encode_voice_hook.invoke<int>(pcm, data, capacity);
            if (size > 0) stats.encoded_bytes += size;
            if (size > 0 && size <= 5) ++stats.tiny_encoded_frames;
            return size;
        }
        void ensure_audio()
        {
            if (!audio_initialized()) utils::hook::invoke<void>(0x140D597C0);
        }
        bool same(const game::netadr_s& a, const game::netadr_s& b)
        {
            return network::are_addresses_equal(a, b);
        }
        void send(const game::netadr_s& to, const wire::packet& p)
        {
            const auto bytes = wire::encode(p);
            if (!bytes.empty()) network::send(to, transport, bytes);
        }
        std::vector<incoming> drain()
        {
            std::lock_guard lock(inbox_mutex);
            std::vector<incoming> result;
            result.swap(inbox); return result;
        }
        void receive(const game::netadr_s& from, const std::string_view& data)
        {
            // Parse before touching engine memory; at most 1200 bytes/10 frames.
            wire::packet p;
            if (from.type != game::NA_IP || (relay_witness &&
                (from.ip[0] != 127 || from.ip[1] || from.ip[2] || from.ip[3] != 1)) ||
                !wire::decode(data, p)) { ++stats.rejected; return; }
            std::lock_guard lock(inbox_mutex);
            if (inbox.size() >= inbox_limit) { ++stats.rejected; return; }
            inbox.push_back({from, std::move(p), now(), static_cast<unsigned>(data.size())});
        }
        void server_tick()
        {
            auto messages = drain();
            std::lock_guard lock(state_mutex);
            const bool enabled = module_enabled();
            if (!zombies() || !game::SV_Loaded() || !enabled) { peers = {}; return; }
            const auto* clients = *game::svs_clients;
            const auto count = std::min(*game::svs_numclients, wire::slots);
            const auto time = now();
            for (unsigned i = 0; i < wire::slots; ++i)
            {
                auto& p = peers[i];
                if (!clients || i >= count || clients[i].header.state != game::CS_ACTIVE || clients[i].remoteAddress.type != game::NA_IP ||
                    (relay_witness && !paris_test_fixture::is_protected_player(static_cast<int>(i))))
                { p = {}; continue; }
                const auto& c = clients[i];
                const std::string identity(c.playerGuid, strnlen(c.playerGuid, sizeof(c.playerGuid)));
                if (!p.identity.empty() && (p.identity != identity || !same(p.address, c.remoteAddress))) p = {};
                if (p.token && time - p.seen > timeout_ms) p = {};
                p.address = c.remoteAddress; p.identity = identity;
            }
            for (auto& msg : messages)
            {
                if (time - msg.time > 500) { ++stats.rejected; continue; }
                unsigned slot = count;
                for (unsigned i = 0; clients && i < count; ++i)
                    if (clients[i].header.state == game::CS_ACTIVE && same(clients[i].remoteAddress, msg.from) &&
                        (!relay_witness || paris_test_fixture::is_protected_player(static_cast<int>(i)))) { slot = i; break; }
                if (slot >= count) { ++stats.rejected; continue; }
                auto& p = peers[slot];
                if (msg.data.type == wire::kind::hello)
                {
                    if (p.hello_time && time - p.hello_time < 500) { ++stats.rejected; continue; }
                    p.hello_time = time;
                    if (!p.token || p.challenge != msg.data.token)
                    {
                        p.token = random_token(); p.challenge = msg.data.token; p.replay = {}; p.rate = {};
                    }
                    p.seen = time;
                    wire::packet reply; reply.type = wire::kind::ready; reply.token = p.token;
                    reply.challenge = p.challenge; reply.speaker = static_cast<unsigned char>(slot);
                    send(p.address, reply); continue;
                }
                if ((msg.data.type != wire::kind::audio && msg.data.type != wire::kind::probe) || !p.token || msg.data.token != p.token ||
                    msg.data.speaker != slot || !p.replay.accept(msg.data.sequence) ||
                    !p.rate.accept(static_cast<unsigned>(msg.data.frames.size()), msg.bytes, time))
                { ++stats.rejected; continue; }
                p.seen = time;
                // Explicit synthetic calibration returns only to its connected sender.
                // It never relays test audio to other players and cannot amplify a datagram.
                if (msg.data.type == wire::kind::probe) { send(p.address, msg.data); continue; }
                for (unsigned i = 0; i < count; ++i)
                {
                    const auto& recipient = peers[i];
                    if (i == slot || !recipient.token || time - recipient.seen > timeout_ms) continue;
                    msg.data.token = recipient.token;
                    send(recipient.address, msg.data); stats.relayed += msg.data.frames.size();
                }
            }
        }
        bool client_connection(game::netadr_s& host)
        {
            const auto* connection = party::get_server_connection_state();
            if (!zombies() || !connection || !connection->hostDefined || connection->host.type != game::NA_IP ||
                !game::CL_IsGameClientActive(0) || game::clientUIActives[0].connectionState != game::CA_ACTIVE) return false;
            host = connection->host;
            return !relay_witness || (host.ip[0] == 127 && !host.ip[1] && !host.ip[2] && host.ip[3] == 1);
        }
        void client_tick()
        {
            auto messages = drain();
            std::lock_guard lock(state_mutex);
            game::netadr_s host{};
            if (!client_connection(host)) { client = {}; return; }
            const auto time = now();
            if (!client.connected || !same(client.host, host))
            {
                client = {}; client.host = host; client.connected = true; client.challenge = random_token();
            }
            if (client.token && time - client.last_ready > timeout_ms)
            {
                client.token = 0; client.challenge = random_token(); client.replay = {}; client.sequence = 0;
            }
            if (time - client.last_hello >= (client.token ? 5000 : 1000))
            {
                wire::packet hello; hello.type = wire::kind::hello; hello.token = client.challenge;
                send(client.host, hello); client.last_hello = time;
            }
            for (const auto& msg : messages)
            {
                if (time - msg.time > 500 || !same(msg.from, client.host)) { ++stats.rejected; continue; }
                const auto& p = msg.data;
                if (p.type == wire::kind::ready && p.challenge == client.challenge)
                {
                    if (p.token != client.token)
                    {
                        client.replay = {}; client.rate = {}; client.sequence = 0;
                        console::info("[paris-voice] Zombies relay ready (protocol 1, slot %u)\n", p.speaker);
                    }
                    client.token = p.token; client.own_slot = p.speaker; client.last_ready = time;
                    if (!relay_witness) ensure_audio();
                    continue;
                }
                if ((p.type != wire::kind::audio && p.type != wire::kind::probe) || !client.token || p.token != client.token ||
                    (p.type == wire::kind::audio && p.speaker == client.own_slot) || (p.type == wire::kind::probe && p.speaker != client.own_slot) ||
                    !client.replay[p.speaker].accept(p.sequence) ||
                    !client.rate[p.speaker].accept(static_cast<unsigned>(p.frames.size()), msg.bytes, time))
                { ++stats.rejected; continue; }
                if (!enabled()) { ++stats.muted; continue; }
                if (!relay_witness) ensure_audio();
                const auto samples = *reinterpret_cast<const int*>(0x145D5C6DC);
                if (!audio_initialized() || samples <= 0 || samples > 4096) { ++stats.rejected; continue; }
                const auto* lobby = game::Lobby_GetPartyData();
                const auto* session = relay_witness ? utils::hook::invoke<game::SessionData*>(0x140D32740) :
                    (lobby ? lobby->session : nullptr);
                if (relay_witness && (!session || !session->dyn.users[p.speaker].registered ||
                    !session->dyn.users[p.speaker].voiceRegistered)) { ++stats.rejected; continue; }
                // Engine scoreboard mute and platform/privacy checks remain in force.
                if (session && utils::hook::invoke<bool>(0x14037BBA0, session, static_cast<int>(p.speaker)))
                { ++stats.muted; continue; }
                for (const auto& frame : p.frames)
                {
                    // The native caller uses no Voice_Incoming return value.
                    // Decoder/queue counters measure work; an arbitrary RAX is
                    // not a delivery result.
                    utils::hook::invoke<void>(0x140D59620, session, static_cast<int>(p.speaker),
                        frame.data(), static_cast<int>(frame.size()), 0);
                }
            }
        }
        void codec_selftest()
        {
            if (game::environment::is_dedi()) { console::warn("[paris-voice] Codec test requires a rendering client; dedicated server has no audio devices.\n"); return; }
            ensure_audio();
            const int samples = utils::hook::invoke<int>(0x140B79440);
            if (!audio_initialized() || samples <= 0 || samples > 4096)
            { console::error("[paris-voice] Codec selftest FAIL: audio initialization/frame size.\n"); return; }
            std::vector<short> input(samples); std::array<char, 256> encoded{}; std::array<short, 8192> decoded{};
            double energy{}; int frames{};
            for (int n = 0; n < 20; ++n)
            {
                for (int i = 0; i < samples; ++i) input[i] = static_cast<short>(10000 * std::sin((n * samples + i) * 0.3455751919));
                const int length = utils::hook::invoke<int>(0x140B794F0, input.data(), encoded.data(), 254);
                if (length <= 0 || length > 254) break;
                const int size = utils::hook::invoke<int>(0x140B79310, encoded.data(), length, decoded.data(), samples);
                if (size != samples * 2) break;
                for (int i = 0; i < samples; ++i) energy += std::abs(static_cast<double>(decoded[i]));
                ++frames;
            }
            console::info("[paris-voice] Codec selftest %s: frames=%d samples=%d pcm_energy=%.0f (synthetic, no microphone/network transmission).\n",
                frames == 20 && energy > 10000 ? "PASS" : "FAIL", frames, samples, energy);
        }
        void network_selftest()
        {
            if (game::environment::is_dedi()) return;
            std::lock_guard lock(state_mutex);
            if (!client.token) { console::warn("[paris-voice] Network selftest requires a ready Zombies relay.\n"); return; }
            ensure_audio();
            const int samples = utils::hook::invoke<int>(0x140B79440);
            if (samples <= 0 || samples > 4096) return;
            std::vector<short> input(samples); std::array<char, 256> buffer{};
            wire::packet p; p.type = wire::kind::probe; p.token = client.token; p.speaker = client.own_slot;
            for (int n = 0; n < 20; ++n)
            {
                for (int i = 0; i < samples; ++i) input[i] = static_cast<short>(7000 * std::sin((n * samples + i) * 6.283185307179586 * 440 / *reinterpret_cast<const int*>(0x141BB2CA0)));
                const int length = utils::hook::invoke<int>(0x140B794F0, input.data(), buffer.data(), 254);
                if (length <= 0 || length > 254) return;
                p.frames.emplace_back(buffer.data(), length);
                if (p.frames.size() == 4)
                {
                    p.sequence = ++client.sequence; send(client.host, p); p.frames.clear();
                }
            }
            console::info("[paris-voice] Network selftest sent 20 synthetic frames; only this client receives the calibration tone.\n");
        }
        void relay_test_tick()
        {
            if (relay_test_frame >= 1000) return;
            {
                std::lock_guard lock(state_mutex);
                if (!client.token || !client.connected || client.host.ip[0] != 127 || !game::CL_IsGameClientActive(0)) return;
            }
            if (!relay_test_begin) relay_test_begin = now() + 60000;
            if (now() < relay_test_begin) return;
            const int samples = utils::hook::invoke<int>(0x140B79440);
            if (samples <= 0 || samples > 4096) return;
            std::vector<short> input(samples); std::array<char, 256> buffer{};
            for (int i = 0; i < samples; ++i) input[i] = static_cast<short>(7000 * std::sin((relay_test_frame * samples + i) * 6.283185307179586 * 440 / *reinterpret_cast<const int*>(0x141BB2CA0)));
            if (utils::flags::has_flag("paris-voice-capture-test"))
            {
                // Development-only post-device PCM injection. Exercise native gain,
                // threshold, encoder and our actual queue hook without recording speech.
                struct capture_buffer { short* pcm; int bytes, samples, sample_bytes; int reserved[3]; int consumed; };
                capture_buffer data{input.data(), samples * 2, samples, 2, {}, 0};
                auto* ptt = *reinterpret_cast<game::dvar_t**>(0x1421EF7A0);
                if (!ptt) return;
                const bool saved = ptt->current.enabled;
                ptt->current.enabled = false;
                capture_voice(&data);
                ptt->current.enabled = saved;
                ++relay_test_frame;
                return;
            }
            const int length = utils::hook::invoke<int>(0x140B794F0, input.data(), buffer.data(), 254);
            if (length <= 0 || length > 254) return;
            std::lock_guard lock(state_mutex);
            wire::packet p; p.type = wire::kind::audio; p.token = client.token; p.speaker = client.own_slot;
            p.sequence = ++client.sequence; p.frames.emplace_back(buffer.data(), length);
            send(client.host, p); ++stats.sent; ++relay_test_frame;
            if (relay_test_frame == 1000) console::info("[paris-voice] Local relay fixture sent 1000 synthetic frames on the normal audio path.\n");
        }
        void gate_selftest()
        {
            if (game::environment::is_dedi() || local_test_gates) return;
            game::netadr_s host{};
            if (!client_connection(host) || host.ip[0] != 127) return;
            unsigned own{};
            { std::lock_guard lock(state_mutex); if (!client.token) return; own = client.own_slot; }
            auto* lobby = game::Lobby_GetPartyData();
            auto* session = lobby ? lobby->session : nullptr;
            if (!session) return;
            int speaker = -1;
            for (unsigned i = 0; i < wire::slots; ++i)
                if (i != own && session->dyn.users[i].registered) { speaker = static_cast<int>(i); break; }
            if (speaker < 0) return; // Wait until the other test client has joined.
            local_test_gates = true;
            auto* voice = const_cast<game::dvar_t*>(game::Dvar_FindVar("cl_voice"));
            auto* ptt = *reinterpret_cast<game::dvar_t**>(0x1421EF7A0);
            const int samples = utils::hook::invoke<int>(0x140B79440);
            if (!voice || !ptt || samples <= 0 || samples > 4096) return;
            std::vector<short> pcm(samples, 10000);
            struct capture_buffer { short* pcm; int bytes, samples, sample_bytes; int reserved[3]; int consumed; };
            const bool saved_voice = voice->current.enabled, saved_ptt = ptt->current.enabled;
            const auto before = stats.sent.load();
            capture_buffer data{pcm.data(), samples * 2, samples, 2, {}, 0};
            voice->current.enabled = false; capture_voice(&data);
            const bool disabled_pass = !enabled() && stats.sent.load() == before;
            voice->current.enabled = true; ptt->current.enabled = true;
            const bool key_released = !utils::hook::invoke<bool>(0x14036FE40, 0);
            data.consumed = 0; capture_voice(&data);
            const bool ptt_pass = key_released && stats.sent.load() == before;
            voice->current.enabled = saved_voice; ptt->current.enabled = saved_ptt;
            const bool saved_mute = session->dyn.users[speaker].muted;
            const bool eligible = utils::hook::invoke<bool>(0x14037B3E0, session, speaker);
            session->dyn.users[speaker].muted = false;
            utils::hook::invoke<void>(0x14037C8A0, session, speaker);
            const bool mute_pass = utils::hook::invoke<bool>(0x14037BBA0, session, speaker);
            utils::hook::invoke<void>(0x14037C8A0, session, speaker);
            const bool unmute_pass = !utils::hook::invoke<bool>(0x14037BBA0, session, speaker);
            session->dyn.users[speaker].muted = saved_mute;
            console::info("[paris-voice] Native gates %s: disabled=%d released_ptt=%d mute_eligible=%d mute=%d unmute=%d (temporary settings restored).\n",
                disabled_pass && ptt_pass && eligible && mute_pass && unmute_pass ? "PASS" : "FAIL",
                disabled_pass, ptt_pass, eligible, mute_pass, unmute_pass);
        }
        int queue_voice(int length, const char* data)
        {
            if (native_trace)
            {
                ++native_encoded;
                const int original = queue_voice_hook.invoke<int>(length, data);
                if (relay_witness)
                {
                    game::netadr_s host{};
                    if (!client_connection(host) || !data || length <= 0 ||
                        length > static_cast<int>(wire::max_frame_bytes)) return original;
                    std::lock_guard lock(state_mutex);
                    if (!client.token || !same(client.host, host) || !enabled()) return original;
                    wire::packet p; p.type = wire::kind::audio; p.token = client.token;
                    p.sequence = ++client.sequence; p.speaker = client.own_slot;
                    p.frames.emplace_back(data, length);
                    send(host, p); ++stats.sent;
                }
                return original;
            }
            // Native capture already applies PTT, mic mute, threshold and cl_voice.
            // Send each encoded frame promptly instead of the legacy 200 ms party batch.
            game::netadr_s host{};
            if (!client_connection(host))
            {
                const auto* connection = party::get_server_connection_state();
                // During a connected Zombies map load, discard stale frames rather
                // than filling the legacy online-party queue with unroutable audio.
                if (zombies() && connection && connection->hostDefined && connection->host.type == game::NA_IP) return length;
                return queue_voice_hook.invoke<int>(length, data);
            }
            std::lock_guard lock(state_mutex);
            ++stats.captured;
            if (!client.connected || !same(client.host, host) || !client.token || !enabled()) return length;
            if (!data || length <= 0 || length > static_cast<int>(wire::max_frame_bytes)) { ++stats.rejected; return length; }
            wire::packet p; p.type = wire::kind::audio; p.token = client.token; p.sequence = ++client.sequence;
            p.speaker = client.own_slot; p.frames.emplace_back(data, length);
            send(client.host, p); ++stats.sent; return length;
        }
        void status()
        {
            std::lock_guard lock(state_mutex);
            unsigned ready{}; for (const auto& p : peers) if (p.token) ++ready;
            console::info("[paris-voice] v1 zombies=%d dedicated=%d ready=%u client_ready=%d audio_init=%d capture=%llu sent=%llu relayed=%llu decoded=%llu pcm_bytes=%llu rejected=%llu muted=%llu\n",
                zombies(), game::environment::is_dedi(), ready, client.token != 0,
                audio_initialized(), stats.captured.load(), stats.sent.load(), stats.relayed.load(), stats.decoded.load(), stats.pcm_bytes.load(), stats.rejected.load(), stats.muted.load());
            if (!game::environment::is_dedi()) console::info("[paris-voice] client mode=%d connection=%d game_active=%d mic_running=%d cl_voice=%d\n",
                game::Com_GameMode_GetActiveGameMode(), game::clientUIActives[0].connectionState,
                game::CL_IsGameClientActive(0), *reinterpret_cast<const unsigned char*>(0x1477A0158) != 0, enabled());
            if (!game::environment::is_dedi())
            {
                unsigned playing{};
                const auto buffers = reinterpret_cast<const unsigned char* const*>(0x1477A01C0);
                for (unsigned i = 0; i < wire::slots; ++i)
                    if (buffers[i] && *reinterpret_cast<const int*>(buffers[i] + 0x44)) ++playing;
                console::info("[paris-voice] playback ds_init=%d rate=%d start_bytes=%d playing=%u queued_bytes=%llu queue_errors=%llu\n",
                    *reinterpret_cast<const unsigned char*>(0x145D5C728) != 0,
                    *reinterpret_cast<const int*>(0x141BB2CA0), *reinterpret_cast<const int*>(0x141BB2C90),
                    playing, stats.queued_bytes.load(), stats.queue_errors.load());
                console::info("[paris-voice] native capture callbacks=%llu\n", stats.capture_blocks.load());
                unsigned registered{};
                const auto* lobby = game::Lobby_GetPartyData();
                if (lobby && lobby->session)
                    for (const auto& user : lobby->session->dyn.users) if (user.registered) ++registered;
                console::info("[paris-voice] native session registered_players=%u\n", registered);
            }
            if (native_trace)
            {
                // Same selected session and local-user lookup used by retail send.
                auto* session = utils::hook::invoke<game::SessionData*>(0x140D32740);
                const int controller = utils::hook::invoke<int>(0x140347690, 0);
                const int local_slot = session ? utils::hook::invoke<int>(0x140D32920, controller, session) : -1;
                unsigned registered{}, voice_registered{};
                if (session) for (const auto& user : session->dyn.users)
                { registered += user.registered; voice_registered += user.voiceRegistered; }
                console::info("[paris-voice-native] mode=%d capture=%llu encoded=%llu batch=%llu send_attempts=%llu send_ok=%llu received=%llu decoded=%llu queued_bytes=%llu session=%d local_slot=%d registered=%u voice_registered=%u legacy_queue=%d\n",
                    game::Com_GameMode_GetActiveGameMode(), stats.capture_blocks.load(), native_encoded.load(),
                    native_batches.load(), native_packets.load(), native_send_ok.load(), native_received.load(),
                    stats.decoded.load(), stats.queued_bytes.load(), session != nullptr, local_slot,
                    registered, voice_registered, *reinterpret_cast<const int*>(0x142255DF8));
                if (!game::environment::is_dedi()) console::info("[paris-voice-native] capture_gate=%d ptt_down=%d mic_activity=%.6f\n",
                    utils::hook::invoke<bool>(0x14037DA00), utils::hook::invoke<bool>(0x14036FE40, 0),
                    static_cast<double>(*reinterpret_cast<const float*>(0x1477A027C)));
            }
            if ((relay_witness || utils::flags::has_flag("iw7-voice-relay")) && !game::environment::is_dedi())
                console::info("[paris-voice-witness] decoded_peak_rms=%.6f decoded_tone_ratio=%.6f decoded_target_frames=%llu; cumulative 997-Hz PCM metrics, no recordings.\n",
                    stats.decoded_peak_rms.load(), stats.decoded_peak_tone_ratio.load(), stats.decoded_target_frames.load());
        }
        void registration_roster_witness()
        {
            if (!native_trace || !native_audio_test() || game::environment::is_dedi() ||
                !utils::flags::has_flag("paris-voice-registration-witness")) return;
            game::netadr_s host{};
            if (!client_connection(host) || host.ip[0] != 127 || host.ip[1] || host.ip[2] || host.ip[3] != 1) return;
            const int controller = utils::hook::invoke<int>(0x140347690, 0);
            const auto identity = game::Live_GetXuid(controller);
            if (!identity) return;
            std::array<char, 16> text{};
            const auto converted = std::to_chars(text.data(), text.data() + text.size(), identity, 16);
            if (converted.ec != std::errc{}) return;
            utils::info_string info;
            info.set("xuid", std::string(text.data(), converted.ptr));
            info.set("gamertag", "Voice test participant");
            info.set("clanAbbrev", "");
            network::send(host, "clientinfo", info.build(), '\n');
            console::info("[paris-voice-native] Loopback metadata announcement sent; existing UI channel only, not production roster authentication.\n");
        }
        void registration_witness(game::SessionData* session, int controller, int local_slot,
            const game::netadr_s& host)
        {
            // A causal loopback experiment only, never a production roster source.
            // UI member metadata lacks the authentication/lifecycle contract that
            // a shipping voice feature requires. Preserve the original route.
            if (!utils::flags::has_flag("paris-voice-registration-witness") || !session ||
                !session->dyn.sessionHandle || local_slot < 0 || local_slot >= static_cast<int>(wire::slots)) return;
            // Match the existing party adapter: retail writes the absent index
            // through EAX (0xFFFFFFFF), not a full-width UINT64_MAX result.
            constexpr std::uint64_t absent_user = 0xFFFFFFFFULL;
            unsigned metadata{}, already_registered{}, invalid{}, attempted{}, added{};
            for (unsigned slot = 0; slot < wire::slots; ++slot)
            {
                if (static_cast<int>(slot) == local_slot || !party::g_clientMemberInfoValid[slot]) continue;
                ++metadata;
                const auto& value = party::g_clientMemberInfo[slot].xuid;
                std::uint64_t identity{};
                if (value.empty() || value.size() > 16) { ++invalid; continue; }
                const auto parsed = std::from_chars(value.data(), value.data() + value.size(), identity, 16);
                if (parsed.ec != std::errc{} || parsed.ptr != value.data() + value.size() || !identity) { ++invalid; continue; }
                if (game::Session_FindRegisteredUser(session, identity) != absent_user) { ++already_registered; continue; }
                // The stock fallback sends through the connected server. This
                // witness supplies no direct remote endpoint or platform address.
                std::array<char, 128> platform_address{};
                ++attempted;
                game::Session_RegisterRemotePlayer(controller, session, identity, false,
                    static_cast<int>(slot), 1, platform_address.data(), &host);
                added += session->dyn.users[slot].registered && session->dyn.users[slot].voiceRegistered;
            }
            console::info("[paris-voice-native] Registration witness metadata=%u known=%u invalid=%u attempted=%u added=%u; loopback experiment, not production authentication.\n",
                metadata, already_registered, invalid, attempted, added);
            for (unsigned slot = 0; slot < wire::slots; ++slot)
            {
                if (static_cast<int>(slot) == local_slot || !session->dyn.users[slot].registered) continue;
                // Read the same retail filters used by recipient selection. Never
                // override their results, mute state or privacy eligibility.
                const bool local = utils::hook::invoke<bool>(0x140C732A0, session, slot);
                const bool muted = utils::hook::invoke<bool>(0x14037BBA0, session, slot);
                const bool shared_channel = utils::hook::invoke<bool>(0x1409C3EF0, local_slot, slot);
                const bool eligible = utils::hook::invoke<bool>(0x14099E210, session, 0, slot);
                console::info("[paris-voice-native] Recipient witness slot=%u local=%d muted=%d shared_channel=%d eligible=%d; native decisions retained.\n",
                    slot, local, muted, shared_channel, eligible);
                const auto globals = utils::hook::invoke<std::uintptr_t>(0x140242BF0, 0);
                const auto cg_static = *reinterpret_cast<const std::uintptr_t*>(0x141FAEE58);
                if (!globals || !cg_static) continue;
                const auto table = *reinterpret_cast<const std::uintptr_t*>(cg_static);
                const auto get_info = *reinterpret_cast<const std::uintptr_t*>(table + 0x30);
                const int view_slot = *reinterpret_cast<const int*>(globals + 0x4AD0);
                if (!get_info || view_slot < 0 || view_slot >= 18) continue;
                const auto remote_info = utils::hook::invoke<std::uintptr_t>(get_info, cg_static, slot);
                const auto local_info = utils::hook::invoke<std::uintptr_t>(get_info, cg_static, view_slot);
                if (!remote_info || !local_info) continue;
                // Inspect the exact client-info fields read by the retail filter;
                // these offsets are research-only, never a production layout API.
                console::info("[paris-voice-native] Client-info witness view_slot=%d remote_valid=%d local_valid=%d remote_team=%d local_team=%d; read-only retail filter inputs.\n",
                    view_slot, *reinterpret_cast<const int*>(remote_info + 4),
                    *reinterpret_cast<const int*>(local_info + 4),
                    *reinterpret_cast<const int*>(remote_info + 12),
                    *reinterpret_cast<const int*>(local_info + 12));
            }
        }
        std::function<void()> cancel_native_probe;
        void run_native_probe(bool hold_talk, bool codec_control = false, int frame_count = 0)
        {
            if (!native_trace || game::environment::is_dedi() || !native_audio_test()) return;
            if (probe_running)
            { console::warn("[paris-voice-native] Probe refused: previous stimulus still active.\n"); return; }
            game::netadr_s host{};
            if (!client_connection(host) || host.ip[0] != 127 || !audio_initialized())
            { console::warn("[paris-voice-native] Probe refused: active loopback and native audio initialization required.\n"); return; }
            auto* session = utils::hook::invoke<game::SessionData*>(0x140D32740);
            const int controller = utils::hook::invoke<int>(0x140347690, 0);
            const int local_slot = session ? utils::hook::invoke<int>(0x140D32920, controller, session) : -1;
            registration_witness(session, controller, local_slot, host);
            const int samples = utils::hook::invoke<int>(0x140B79440);
            if (samples <= 0 || samples > 4096) return;
            auto* ptt = *reinterpret_cast<game::dvar_t**>(0x1421EF7A0);
            if (!ptt || !enabled() || utils::hook::invoke<bool>(0x14036FE40, 0)) return;
            int talk_binding = 0;
            for (int i = 1; i < 117; ++i)
                if (game::command_whitelist[i] && game::command_whitelist[i + 1] &&
                    !std::strcmp(game::command_whitelist[i], "+talk") && !std::strcmp(game::command_whitelist[i + 1], "-talk"))
                { talk_binding = i; break; }
            if (!talk_binding) return;
            auto* encoder = *reinterpret_cast<void**>(0x145D5C6E8);
            int vad{}, dtx{}, vbr{}, abr{}, configured_mode{}, quality{}, cached_quality{};
            const auto encoder_ctl = [](void* context, int request, int* value)
            { return utils::hook::invoke<int>(0x1405E9520, context, request, value); };
            if (codec_control)
            {
                // Private synthetic-signal control only. Production preserves
                // native VAD/DTX/VBR, which may alter a steady test tone.
                if (!utils::flags::has_flag("iw7-voice-relay") || host.ip[0] != 127 || host.ip[1] || host.ip[2] || host.ip[3] != 1 || !encoder ||
                    encoder_ctl(encoder, 31, &vad) || encoder_ctl(encoder, 35, &dtx) ||
                    encoder_ctl(encoder, 13, &vbr) || encoder_ctl(encoder, 33, &abr)) return;
                // Native VAD may leave the current submode at null (DTX).
                // Disabling VAD alone retains that null mode. Reapply the saved
                // configured narrowband submode, without resetting codec state.
                // The pinned native ctl's SET_MODE (6) writes current+selected;
                // selected is at +0x174 and remains the user's configuration.
                configured_mode = *reinterpret_cast<const int*>(static_cast<const char*>(encoder) + 0x174);
                if (configured_mode < 1 || configured_mode > 8) return;
                quality = *reinterpret_cast<const int*>(0x1415062D8);
                cached_quality = *reinterpret_cast<const int*>(0x141BB2C7C);
                if (quality < 0 || quality > 10 || cached_quality < 0 || cached_quality > 10) return;
                int off{};
                console::info("[paris-voice-native] Codec baseline vad=%d dtx=%d vbr=%d abr=%d configured_mode=%d.\n", vad, dtx, vbr, abr, configured_mode);
                console::info("[paris-voice-native] Codec quality=%d cached_quality=%d.\n", quality, cached_quality);
                if (encoder_ctl(encoder, 30, &off) || encoder_ctl(encoder, 34, &off) ||
                    encoder_ctl(encoder, 12, &off) || encoder_ctl(encoder, 6, &configured_mode))
                {
                    encoder_ctl(encoder, 6, &configured_mode);
                    encoder_ctl(encoder, 30, &vad); encoder_ctl(encoder, 34, &dtx);
                    encoder_ctl(encoder, 12, &vbr); return;
                }
            }
            const bool saved_ptt = ptt->current.enabled;
            // Explicit post-device witness. No microphone recording and no
            // transport override. This is never evidence of human speech.
            std::vector<short> pcm(samples, 10000);
            // A synthetic block does not update the hardware mic-activity meter.
            // Use a paired retail PTT binding for this post-device witness; the
            // earlier activity-mode attempt encoded zero and is inconclusive.
            probe_running = true;
            ptt->current.enabled = true;
            // Common dispatcher handles talk before the MP/SP gameplay dispatcher.
            if (hold_talk) utils::hook::invoke<void>(0x14032A3B0, 0, talk_binding, 86, 1);
            const bool pressed = utils::hook::invoke<bool>(0x14036FE40, 0);
            const bool generic_relay = utils::flags::has_flag("iw7-voice-relay");
            const auto probe_begin = GetTickCount64();
            console::info("[paris-voice-native] Synthetic witness begins: hold_talk=%d tick_ms=%llu.\n", hold_talk, probe_begin);
            const auto encoded_before = generic_relay ? voice_relay::encoded_frames() : native_encoded.load();
            const auto bytes_before = stats.encoded_bytes.load(), tiny_before = stats.tiny_encoded_frames.load();
            const auto device_before = probe_device_blocks.load();
            const int frames = frame_count ? frame_count : ((relay_witness || generic_relay) ? 60 : 20);
            auto active = std::make_shared<std::atomic<bool>>(true);
            auto finish = [=](bool aborted) mutable
            {
                if (!active->exchange(false)) return;
                if (hold_talk) utils::hook::invoke<void>(0x14032A3B0, 0, talk_binding + 1, 86, 1);
                if (ptt == *reinterpret_cast<game::dvar_t**>(0x1421EF7A0)) ptt->current.enabled = saved_ptt;
                if (codec_control && encoder == *reinterpret_cast<void**>(0x145D5C6E8))
                {
                    // The original first encode may consume a pending quality
                    // change. Restore that cache together with the selected
                    // submode, or the native dvar and encoder become inconsistent
                    // after this private calibration. Never undo a user change.
                    const bool quality_unchanged = quality == *reinterpret_cast<const int*>(0x1415062D8);
                    const int observed_mode = *reinterpret_cast<const int*>(static_cast<const char*>(encoder) + 0x174);
                    if (quality_unchanged)
                    {
                        *reinterpret_cast<int*>(0x141BB2C7C) = cached_quality;
                        encoder_ctl(encoder, 6, &configured_mode);
                    }
                    encoder_ctl(encoder, 30, &vad); encoder_ctl(encoder, 34, &dtx);
                    encoder_ctl(encoder, 12, &vbr);
                    int after_vad{}, after_dtx{}, after_vbr{}, after_abr{};
                    const bool restored = !encoder_ctl(encoder, 31, &after_vad) && !encoder_ctl(encoder, 35, &after_dtx) &&
                        !encoder_ctl(encoder, 13, &after_vbr) && !encoder_ctl(encoder, 33, &after_abr) &&
                        after_vad == vad && after_dtx == dtx && after_vbr == vbr && after_abr == abr && quality_unchanged;
                    const int after_mode = *reinterpret_cast<const int*>(static_cast<const char*>(encoder) + 0x174);
                    console::info("[paris-voice-native] Codec control restored=%d vad=%d dtx=%d configured_mode=%d mode_preserved=%d.\n", restored,
                        after_vad, after_dtx, after_mode, after_mode == configured_mode);
                    console::info("[paris-voice-native] Codec adaptive settings vbr=%d abr=%d restored=%d.\n", after_vbr, after_abr, restored);
                    console::info("[paris-voice-native] Codec observed_mode=%d cached_quality_restored=%d.\n", observed_mode,
                        quality_unchanged && cached_quality == *reinterpret_cast<const int*>(0x141BB2C7C));
                }
                probe_running = false;
                console::info("[paris-voice-native] Synthetic post-device witness: pressed=%d released=%d encoded_delta=%llu; PTT setting restored.\n",
                    pressed, !utils::hook::invoke<bool>(0x14036FE40, 0),
                    (generic_relay ? voice_relay::encoded_frames() : native_encoded.load()) - encoded_before);
                console::info("[paris-voice-native] Synthetic witness returned: duration_ms=%llu tick_ms=%llu aborted=%d.\n", GetTickCount64() - probe_begin, GetTickCount64(), aborted);
                console::info("[paris-voice-native] Codec control=%d encoded_bytes_delta=%llu tiny_frames_delta=%llu device_blocks_replaced=%llu.\n", codec_control,
                    stats.encoded_bytes.load() - bytes_before, stats.tiny_encoded_frames.load() - tiny_before,
                    probe_device_blocks.load() - device_before);
                status();
            };
            cancel_native_probe = [finish]() mutable { finish(true); };
            // Return to the engine between capture blocks so a speaking client
            // can receive other speakers. Bound catch-up after a delayed frame;
            // never turn scheduler starvation into an unbounded packet burst.
            scheduler::schedule([=, pcm = std::move(pcm), index = 0, due = probe_begin]() mutable
            {
                if (!active->load()) return scheduler::cond_end;
                game::netadr_s current{};
                const auto time = GetTickCount64();
                if (!client_connection(current) || !network::are_addresses_equal(current, host) ||
                    session != utils::hook::invoke<game::SessionData*>(0x140D32740) ||
                    !audio_initialized() || (codec_control && encoder != *reinterpret_cast<void**>(0x145D5C6E8)) ||
                    time > due + 500)
                { finish(true); return scheduler::cond_end; }
                for (unsigned emitted = 0; index < frames && time >= due && emitted < 4; ++emitted, ++index, due += 20)
                {
                    if (relay_witness || generic_relay) for (int sample = 0; sample < samples; ++sample)
                        pcm[sample] = static_cast<short>(10000 * std::sin(6.283185307179586 *
                            (index < 20 ? 440 : 997) * (index * samples + sample) / 8000.0));
                    capture_buffer block{pcm.data(), samples * 2, samples, 2, {}, 0};
                    ++stats.capture_blocks;
                    capture_voice_hook.invoke<int>(&block);
                }
                if (index < frames) return scheduler::cond_continue;
                finish(false);
                return scheduler::cond_end;
            }, scheduler::main);
        }
        void native_probe() { run_native_probe(true); }
        void native_released_probe() { run_native_probe(false); }
        void native_codec_probe() { run_native_probe(true, true); }
        void native_concurrent_probe() { run_native_probe(true, true, 500); }
        void native_soak_probe() { run_native_probe(true, true, 15000); }

        struct control_baseline
        {
            game::dvar_t* voice{};
            game::SessionData* session{};
            std::uint64_t user{};
            int slot{-1};
            bool active{}, enabled{}, muted{};
        } test_controls;
        void restore_test_controls()
        {
            if (probe_running && cancel_native_probe) cancel_native_probe();
            if (!test_controls.active) return;
            if (test_controls.voice && test_controls.voice->type == game::DVAR_TYPE_BOOL)
                game::Dvar_SetBool(test_controls.voice, test_controls.enabled);
            auto* current = utils::hook::invoke<game::SessionData*>(0x140D32740);
            if (current == test_controls.session && current && current->dyn.sessionHandle &&
                test_controls.slot >= 0 && test_controls.slot < static_cast<int>(wire::slots) &&
                current->dyn.users[test_controls.slot].registered && current->dyn.users[test_controls.slot].xuid == test_controls.user)
                utils::hook::invoke<void>(test_controls.muted ? 0x140D59AC0 : 0x140D59FE0, current, test_controls.slot);
            test_controls = {};
            console::info("[paris-voice-native] Temporary native voice controls restored; prior speaker binding required.\n");
        }
        void test_control(const char* action)
        {
            if (!native_trace || !native_audio_test() || game::environment::is_dedi() ||
                !utils::flags::has_flag("iw7-voice-relay")) return;
            game::netadr_s host{};
            if (!client_connection(host) || host.ip[0] != 127 || host.ip[1] || host.ip[2] || host.ip[3] != 1) return;
            auto* current = utils::hook::invoke<game::SessionData*>(0x140D32740);
            auto* voice = const_cast<game::dvar_t*>(game::Dvar_FindVar("cl_voice"));
            if (!current || !current->dyn.sessionHandle || !voice || voice->type != game::DVAR_TYPE_BOOL) return;
            const int controller = utils::hook::invoke<int>(0x140347690, 0);
            const int own = utils::hook::invoke<int>(0x140D32920, controller, current);
            if (own < 0 || own >= static_cast<int>(wire::slots)) return;
            int remote = -1;
            for (unsigned slot = 0; slot < wire::slots; ++slot)
                if (static_cast<int>(slot) != own && current->dyn.users[slot].registered && current->dyn.users[slot].voiceRegistered)
                { if (remote >= 0) return; remote = static_cast<int>(slot); }
            if (remote < 0) return; // Exactly one remote test participant.
            if (!test_controls.active)
                test_controls = {voice, current, current->dyn.users[remote].xuid, remote, true, voice->current.enabled, current->dyn.users[remote].muted};
            if (test_controls.session != current || test_controls.slot != remote || test_controls.user != current->dyn.users[remote].xuid) return;
            if (!std::strcmp(action, "mute")) utils::hook::invoke<void>(0x140D59AC0, current, remote);
            else if (!std::strcmp(action, "unmute"))
                utils::hook::invoke<void>(test_controls.muted ? 0x140D59AC0 : 0x140D59FE0, current, remote);
            else if (!std::strcmp(action, "disable")) game::Dvar_SetBool(voice, false);
            else if (!std::strcmp(action, "enable")) game::Dvar_SetBool(voice, test_controls.enabled);
            console::info("[paris-voice-native] Temporary control=%s cl_voice=%d native_muted=%d; baseline retained for restore.\n",
                action, voice->current.enabled, utils::hook::invoke<bool>(0x14037BBA0, current, remote));
        }
        void register_witness()
        {
            if (!native_trace || !native_audio_test() || game::environment::is_dedi() ||
                !utils::flags::has_flag("paris-voice-registration-witness")) return;
            game::netadr_s host{};
            if (!client_connection(host) || host.ip[0] != 127 || host.ip[1] || host.ip[2] || host.ip[3] != 1) return;
            auto* session = utils::hook::invoke<game::SessionData*>(0x140D32740);
            const int controller = utils::hook::invoke<int>(0x140347690, 0);
            const int slot = session ? utils::hook::invoke<int>(0x140D32920, controller, session) : -1;
            registration_witness(session, controller, slot, host);
            status();
        }
    }
    class component final : public component_interface
    {
    public:
        void post_unpack() override
        {
            native_trace = utils::flags::has_flag("paris-voice-native-trace");
            // The generic component owns the queue in its opt-in profile. Keep
            // only independent forwarding diagnostics for the private harness.
            const bool generic_relay = utils::flags::has_flag("iw7-voice-relay");
            if (generic_relay && !native_trace) return;
            relay_witness = native_trace && utils::flags::has_flag("paris-voice-relay-witness");
            if (relay_witness && !game::environment::is_dedi() &&
                !utils::flags::has_flag("paris-voice-registration-witness"))
            {
                console::error("[paris-voice-native] Relay witness refused: explicit registration witness required.\n");
                return;
            }
            if (native_trace && (!native_audio_test() || !trace_signatures_match()))
            {
                console::error("[paris-voice-native] Trace refused: explicit protected audio test/signatures required.\n");
                return;
            }
            scheduler::once([] { game::Dvar_RegisterBool("paris_voice_available", !native_trace, 0, "Voice transport installed; matching clients required"); }, scheduler::main);
            if (!native_trace || relay_witness) network::on(transport, receive);
            command::add("paris_voice_status", status);
            command::add("paris_voice_selftest", codec_selftest);
            command::add("paris_voice_network_test", network_selftest);
            command::add("paris_voice_gate_selftest", gate_selftest);
            command::add("paris_voice_native_probe", native_probe);
            command::add("paris_voice_native_released_probe", native_released_probe);
            command::add("paris_voice_native_codec_probe", native_codec_probe);
            command::add("paris_voice_native_concurrent_probe", native_concurrent_probe);
            command::add("paris_voice_native_soak_probe", native_soak_probe);
            command::add("paris_voice_test_mute", [] { test_control("mute"); });
            command::add("paris_voice_test_unmute", [] { test_control("unmute"); });
            command::add("paris_voice_test_disable", [] { test_control("disable"); });
            command::add("paris_voice_test_enable", [] { test_control("enable"); });
            command::add("paris_voice_test_restore", restore_test_controls);
            command::add("paris_voice_registration_roster", registration_roster_witness);
            command::add("paris_voice_register_witness", register_witness);
            if (native_trace)
            {
                if (!game::environment::is_dedi()) scripting::on_shutdown([](bool, bool post)
                {
                    if (!post) restore_test_controls();
                });
                native_receive_hook.create(0x14037CFF0, native_receive);
                native_send_hook.create(0x14037BFF0, native_send);
                scheduler::loop(status, scheduler::main, 10s);
            }
            if (utils::flags::has_flag("paris-voice-diagnostics")) scheduler::loop(status, scheduler::main, 10s);
            if (game::environment::is_dedi()) { if (!native_trace || relay_witness) scheduler::loop(server_tick, scheduler::server, 10ms); }
            else
            {
                // The lab uses the connect fixture without opening custom
                // microphone/output sessions or emitting calibration tones.
                if (!utils::flags::has_flag("paris-isolated-lab") || utils::flags::has_flag("paris-voice-audio-lab"))
                {
                    if (!generic_relay) queue_voice_hook.create(0x14037D960, queue_voice);
                    decode_voice_hook.create(0x140B79310, decode_voice);
                    enqueue_voice_hook.create(0x140B79B60, enqueue_voice);
                    capture_voice_hook.create(0x140B79D30, capture_voice);
                    if (native_trace) encode_voice_hook.create(0x140B794F0, encode_voice);
                    if (native_trace) native_batch_hook.create(0x14037D5C0, native_batch);
                    if (!native_trace || relay_witness) scheduler::loop(client_tick, scheduler::main, 10ms);
                }
                if (utils::flags::has_flag("paris-voice-selftest")) scheduler::once(codec_selftest, scheduler::main, 20s);
                if (utils::flags::has_flag("paris-voice-local-test"))
                {
                    scheduler::loop([]
                    {
                        if (local_test_connected) return;
                        if (!zombies()) { game::Com_GameMode_SetDesiredGameMode(game::GAME_MODE_CP); return; }
                        if (game::Live_SyncOnlineDataFlags(0) != 0) return;
                        game::netadr_s target{};
                        const auto fixture_port = utils::flags::has_flag("paris-isolated-lab") ? 27116 : 27016;
                        target.type = game::NA_IP; target.ip[0] = 127; target.ip[3] = 1; target.port = htons(static_cast<unsigned short>(fixture_port));
                        console::info("[paris-voice] Local development fixture connecting to UDP %d (mode %d).\n", fixture_port, game::Com_GameMode_GetActiveGameMode());
                        local_test_connected = true;
                        party::connect(target);
                    }, scheduler::main, 1s);
                    if (utils::flags::has_flag("paris-voice-relay-test")) scheduler::loop(relay_test_tick, scheduler::main, 20ms);
                    if (utils::flags::has_flag("paris-voice-gate-test")) scheduler::loop(gate_selftest, scheduler::main, 1s);
                    scheduler::loop([]
                    {
                        bool ready{};
                        { std::lock_guard lock(state_mutex); ready = client.token != 0; }
                        if (ready && !local_test_probed) { local_test_probed = true; network_selftest(); }
                    }, scheduler::main, 1s);
                    scheduler::once([] { game::Com_Quit_f(); }, scheduler::main, 300s);
                }
            }
            if (native_trace) console::info("[paris-voice-native] Forwarding trace installed; original capture/session/transport/playback retained.\n");
            else console::info("[paris-voice] Native Zombies relay v1 installed; every participant needs this client build.\n");
            if (relay_witness) console::warn("[paris-voice-native] LOOPBACK relay playback witness only; legacy generation defect retained, not a production feature.\n");
        }
    };
}
REGISTER_COMPONENT(paris_voice::component)
