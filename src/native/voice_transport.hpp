#pragma once
#include "voice_wire.hpp"
#include <algorithm>
#include <functional>
#include <stdexcept>

// Engine-independent transport. All times are monotonic milliseconds. The
// adapter supplies only current, game-accepted connections and authorized
// source slots; endpoints and engine pointers never enter this core.
namespace voice::transport
{
    using id = state::session_id;
    using random_source = std::function<id()>;
    constexpr std::uint64_t lease_ms = 15000, challenge_ms = 5000;

    inline id generate(const random_source& random)
    {
        const auto value = random();
        if (value.empty())
            throw std::runtime_error("Voice random source returned an empty generation");
        return value;
    }

    class budget
    {
    public:
        budget(unsigned capacity = 100, unsigned per_second = 60)
            : capacity_(capacity * 1000ull), refill_(per_second), available_(capacity_)
        {
        }
        bool accept(unsigned cost, std::uint64_t time)
        {
            if (started_ && time < last_)
                return false;
            if (started_)
            {
                const auto elapsed = time - last_;
                const auto missing = capacity_ - available_;
                // Saturate before multiplying: long silence must refill the
                // whole bucket without overflowing the monotonic time product.
                if (refill_ && elapsed >= (missing + refill_ - 1) / refill_)
                    available_ = capacity_;
                else
                    available_ += elapsed * refill_;
            }
            started_ = true;
            last_ = time;
            if (cost * 1000ull > available_)
                return false;
            available_ -= cost * 1000ull;
            return true;
        }

    private:
        std::uint64_t capacity_, refill_, available_, last_{};
        bool started_{};
    };

    struct connection
    {
        std::uint64_t user{};
        id incarnation{}; // Changes on every accepted join, even same UID/endpoint.
        bool active{};
        friend bool operator==(const connection& a, const connection& b)
        {
            return a.user == b.user && a.incarnation == b.incarnation && a.active == b.active;
        }
        friend bool operator!=(const connection& a, const connection& b)
        {
            return !(a == b);
        }
    };
    using connections = std::array<connection, state::max_speakers>;
    struct delivery
    {
        unsigned slot{};
        wire::message data;
    };

    class server
    {
    public:
        explicit server(random_source random) : random_(std::move(random))
        {
            reset();
        }
        void reset()
        {
            epoch_ = generate(random_);
            peers_ = {};
            connections_ = {};
            revision_ = 1;
        }
        id epoch() const
        {
            return epoch_;
        }
        std::uint32_t ready_mask() const
        {
            std::uint32_t mask{};
            for (unsigned slot = 0; slot < peers_.size(); ++slot)
                if (!peers_[slot].recipient.empty()) mask |= 1u << slot;
            return mask;
        }

        std::vector<delivery> synchronize(const connections& current, std::uint64_t time)
        {
            bool changed = false;
            for (unsigned slot = 0; slot < state::max_speakers; ++slot)
            {
                auto valid = current[slot];
                if (!valid.active || !valid.user || valid.incarnation.empty())
                    valid = {};
                // A duplicate game identity is not a usable voice roster.
                for (unsigned other = 0; other < slot; ++other)
                    if (valid.active && valid.user == connections_[other].user)
                        valid = {};
                auto& peer = peers_[slot];
                if (valid != connections_[slot] ||
                    (!peer.recipient.empty() && time >= peer.seen && time - peer.seen > lease_ms))
                {
                    changed |= !peer.recipient.empty();
                    peer = {};
                }
                connections_[slot] = valid;
            }
            if (!changed)
                return {};
            ++revision_;
            return snapshots();
        }

        bool receive(unsigned slot, const wire::message& message, unsigned bytes,
                     std::uint64_t time, std::vector<delivery>& output)
        {
            output.clear();
            const auto canonical = wire::encode(message);
            if (slot >= state::max_speakers || !connections_[slot].active || canonical.empty() ||
                bytes != canonical.size())
                return false;
            auto& peer = peers_[slot];
            if (message.type == wire::kind::hello)
            {
                if (message.nonce.empty() || !peer.controls.accept(1, time))
                    return false;
                id challenge{};
                if (!peer.recipient.empty() && message.nonce == peer.confirmed_nonce)
                    challenge =
                        peer.confirmed_challenge; // Lost welcome: never rotate a live capability.
                else
                {
                    if (message.nonce != peer.pending_nonce || time < peer.pending_time ||
                        time - peer.pending_time > challenge_ms)
                    {
                        peer.pending_nonce = message.nonce;
                        peer.pending_challenge = generate(random_);
                        peer.pending_time = time;
                    }
                    challenge = peer.pending_challenge;
                }
                wire::message reply;
                reply.type = wire::kind::challenge;
                reply.nonce = message.nonce;
                reply.server = epoch_;
                reply.challenge = challenge;
                output.push_back({slot, std::move(reply)});
                return true;
            }
            if (message.type == wire::kind::confirm)
            {
                if (message.server != epoch_ || !peer.controls.accept(1, time))
                    return false;
                if (!peer.recipient.empty() && message.nonce == peer.confirmed_nonce &&
                    message.challenge == peer.confirmed_challenge)
                {
                    output.push_back({slot, snapshot(slot, true)});
                    return true;
                }
                if (peer.pending_nonce.empty() || message.nonce != peer.pending_nonce ||
                    message.challenge != peer.pending_challenge || time < peer.pending_time ||
                    time - peer.pending_time > challenge_ms)
                    return false;
                peer.recipient = generate(random_);
                peer.generation = generate(random_);
                peer.confirmed_nonce = peer.pending_nonce;
                peer.confirmed_challenge = peer.pending_challenge;
                peer.pending_nonce = {};
                peer.pending_challenge = {};
                peer.seen = time;
                peer.sequence = {};
                peer.frames = {};
                peer.bytes = budget(24000, 16000);
                ++revision_;
                output = snapshots();
                // The welcome binds the new listener capability to its live challenge.
                for (auto& item : output)
                    if (item.slot == slot)
                        item.data = snapshot(slot, true);
                return true;
            }
            if (peer.recipient.empty() || message.server != epoch_ ||
                message.recipient != peer.recipient || time < peer.seen ||
                time - peer.seen > lease_ms)
                return false;
            if (message.type == wire::kind::heartbeat)
            {
                if (!peer.controls.accept(1, time))
                    return false;
                peer.seen = time;
                output.push_back({slot, snapshot(slot, false)});
                return true;
            }
            if (message.type != wire::kind::audio_up || message.frames.empty() ||
                message.frames.size() > wire::max_frames ||
                !peer.frames.accept(static_cast<unsigned>(message.frames.size()), time) ||
                !peer.bytes.accept(bytes, time) || !peer.sequence.accept(message.sequence))
                return false;
            peer.seen = time;
            for (unsigned target = 0; target < state::max_speakers; ++target)
            {
                const auto& recipient = peers_[target];
                if (slot == target || recipient.recipient.empty() || time < recipient.seen ||
                    time - recipient.seen > lease_ms)
                    continue;
                wire::message audio;
                audio.type = wire::kind::audio_down;
                audio.server = epoch_;
                audio.recipient = recipient.recipient;
                audio.slot = static_cast<unsigned char>(slot);
                audio.generation = peer.generation;
                audio.sequence = message.sequence;
                audio.frames = message.frames;
                output.push_back({target, std::move(audio)});
            }
            return true;
        }

    private:
        struct peer
        {
            id recipient{}, generation{}, pending_nonce{}, pending_challenge{}, confirmed_nonce{},
                confirmed_challenge{};
            std::uint64_t pending_time{}, seen{};
            state::sequence_window sequence;
            budget controls{8, 4}, frames{}, bytes{24000, 16000};
        };
        wire::message snapshot(unsigned slot, bool welcome) const
        {
            wire::message value;
            value.type = welcome ? wire::kind::welcome : wire::kind::roster;
            value.server = epoch_;
            value.recipient = peers_[slot].recipient;
            value.slot = static_cast<unsigned char>(slot);
            if (welcome)
            {
                value.nonce = peers_[slot].confirmed_nonce;
                value.challenge = peers_[slot].confirmed_challenge;
            }
            value.members.server = epoch_;
            value.members.listener = value.recipient;
            value.members.revision = revision_;
            for (unsigned i = 0; i < state::max_speakers; ++i)
                if (!peers_[i].recipient.empty())
                    value.members.speakers[i] = {connections_[i].user, peers_[i].generation, true};
            return value;
        }
        std::vector<delivery> snapshots() const
        {
            std::vector<delivery> result;
            for (unsigned slot = 0; slot < state::max_speakers; ++slot)
                if (!peers_[slot].recipient.empty())
                    result.push_back({slot, snapshot(slot, false)});
            return result;
        }
        random_source random_;
        id epoch_{};
        std::uint64_t revision_{};
        connections connections_{};
        std::array<peer, state::max_speakers> peers_{};
    };

    struct received
    {
        bool accepted{}, audio{};
        std::uint32_t changed_slots{};
    };
    class client
    {
    public:
        client(std::uint64_t user, random_source random) : user_(user), random_(std::move(random))
        {
            reset();
        }
        void reset()
        {
            nonce_ = generate(random_);
            server_ = {};
            challenge_ = {};
            recipient_ = {};
            own_generation_ = {};
            sequence_ = 0;
            sent_ = seen_ = attempt_time_ = 0;
            timer_started_ = attempt_started_ = false;
            state_.reset();
            rates_ = {};
        }
        bool ready() const
        {
            return !recipient_.empty();
        }
        unsigned own_slot() const
        {
            return slot_;
        }
        const state::roster& roster() const
        {
            return state_.current_roster();
        }

        std::vector<wire::message> tick(std::uint64_t time)
        {
            if (ready() && (time < seen_ || time - seen_ > lease_ms))
                reset();
            if (!ready() && attempt_started_ &&
                (time < attempt_time_ || time - attempt_time_ > challenge_ms))
                reset();
            if (!attempt_started_)
            {
                attempt_started_ = true;
                attempt_time_ = time;
            }
            if (timer_started_ && time >= sent_ && time - sent_ < (ready() ? 1000u : 500u))
                return {};
            timer_started_ = true;
            sent_ = time;
            wire::message message;
            if (ready())
            {
                message.type = wire::kind::heartbeat;
                message.server = server_;
                message.recipient = recipient_;
            }
            else if (!challenge_.empty())
            {
                message.type = wire::kind::confirm;
                message.nonce = nonce_;
                message.server = server_;
                message.challenge = challenge_;
            }
            else
            {
                message.type = wire::kind::hello;
                message.nonce = nonce_;
            }
            return {message};
        }

        received receive(const wire::message& message, unsigned bytes, std::uint64_t time)
        {
            received result;
            const auto canonical = wire::encode(message);
            if (canonical.empty() || bytes != canonical.size())
                return result;
            if (ready() && (time < seen_ || time - seen_ > lease_ms))
            {
                reset();
                return result;
            }
            if (message.type == wire::kind::challenge && !ready() && message.nonce == nonce_ &&
                !message.server.empty() && !message.challenge.empty())
            {
                server_ = message.server;
                challenge_ = message.challenge;
                timer_started_ = false;
                result.accepted = true;
                return result;
            }
            if (message.type == wire::kind::welcome || message.type == wire::kind::roster)
            {
                if (message.server != server_ || message.slot >= state::max_speakers ||
                    !message.members.speakers[message.slot].present ||
                    message.members.speakers[message.slot].user != user_ ||
                    message.members.server != message.server ||
                    message.members.listener != message.recipient)
                    return result;
                if (message.type == wire::kind::welcome)
                {
                    if (challenge_.empty() || message.nonce != nonce_ ||
                        message.challenge != challenge_)
                        return result;
                }
                else if (!ready())
                    return result;
                if (ready() && (message.recipient != recipient_ || message.slot != slot_ ||
                                message.members.speakers[slot_].generation != own_generation_))
                    return result;
                auto candidate = state_;
                if (!ready() && !candidate.begin_session(server_, message.recipient))
                    return result;
                const auto status = candidate.apply_roster(message.members, result.changed_slots);
                if (status != state::control_result::applied &&
                    status != state::control_result::repeated)
                    return {};
                state_ = candidate;
                recipient_ = message.recipient;
                slot_ = message.slot;
                own_generation_ = message.members.speakers[slot_].generation;
                seen_ = time;
                for (unsigned slot = 0; slot < state::max_speakers; ++slot)
                    if (result.changed_slots & (1u << slot))
                        rates_[slot] = {};
                result.accepted = true;
                return result;
            }
            if (!ready() || message.type != wire::kind::audio_down || message.slot == slot_ ||
                message.slot >= state::max_speakers || message.frames.empty() ||
                message.frames.size() > wire::max_frames || message.server != server_ ||
                message.recipient != recipient_ ||
                !state_.current_roster().speakers[message.slot].present ||
                state_.current_roster().speakers[message.slot].generation != message.generation ||
                !rates_[message.slot].accept(static_cast<unsigned>(message.frames.size()), time) ||
                !state_.accept_audio(message.server, message.recipient, message.slot,
                                     message.generation, message.sequence))
                return result;
            result.accepted = result.audio = true;
            return result;
        }

        wire::message audio(std::string_view encoded)
        {
            wire::message value;
            if (!ready() || encoded.empty() || encoded.size() > wire::max_frame_bytes)
                return value;
            value.type = wire::kind::audio_up;
            value.server = server_;
            value.recipient = recipient_;
            value.sequence = ++sequence_;
            value.frames.emplace_back(encoded);
            return value;
        }

    private:
        std::uint64_t user_{};
        random_source random_;
        id nonce_{}, server_{}, challenge_{}, recipient_{}, own_generation_{};
        unsigned char slot_{};
        std::uint32_t sequence_{};
        std::uint64_t sent_{}, seen_{}, attempt_time_{};
        bool timer_started_{}, attempt_started_{};
        state::listener state_;
        std::array<budget, state::max_speakers> rates_{};
    };
}
