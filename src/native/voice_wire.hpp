#pragma once
#include "voice_state.hpp"
#include <string>
#include <string_view>
#include <vector>

namespace voice::wire
{
    constexpr unsigned version = 2;
    constexpr unsigned max_frames = 10;
    constexpr unsigned max_frame_bytes = 254;
    constexpr unsigned max_packet_bytes = 1200;
    // A relayed frame adds the speaker slot and 128-bit speaker generation.
    // Reserve those bytes in uplinks so every accepted batch can be relayed.
    constexpr unsigned relay_header_bytes = 1 + 16;
    enum class kind : unsigned char
    {
        hello = 1,
        challenge,
        confirm,
        welcome,
        heartbeat,
        roster,
        audio_up,
        audio_down
    };

    struct message
    {
        kind type{};
        state::session_id nonce{}, server{}, challenge{}, recipient{}, generation{};
        unsigned char slot{};
        std::uint32_t sequence{};
        state::roster members{};
        std::vector<std::string> frames;
    };

    namespace detail
    {
        inline void put(std::string& out, std::uint64_t value, unsigned size)
        {
            for (unsigned i = 0; i < size; ++i)
                out.push_back(static_cast<char>(value >> (i * 8)));
        }
        inline void put_id(std::string& out, state::session_id value)
        {
            put(out, value.low, 8);
            put(out, value.high, 8);
        }
        class reader
        {
        public:
            explicit reader(std::string_view data) : data_(data)
            {
            }
            bool read(unsigned size, std::uint64_t& value)
            {
                if (size > data_.size() - position_)
                    return false;
                value = 0;
                for (unsigned i = 0; i < size; ++i)
                    value |= std::uint64_t(static_cast<unsigned char>(data_[position_++]))
                             << (i * 8);
                return true;
            }
            bool id(state::session_id& value)
            {
                return read(8, value.low) && read(8, value.high) && !value.empty();
            }
            bool block(std::size_t size, std::string& value)
            {
                if (size > data_.size() - position_)
                    return false;
                value.assign(data_.substr(position_, size));
                position_ += size;
                return true;
            }
            bool done() const
            {
                return position_ == data_.size();
            }

        private:
            std::string_view data_;
            std::size_t position_{};
        };
    }

    inline std::string encode(const message& value)
    {
        using namespace detail;
        std::string out("IV", 2);
        put(out, version, 1);
        put(out, static_cast<unsigned char>(value.type), 1);
        const bool handshake = value.type >= kind::hello && value.type <= kind::welcome;
        if (handshake)
        {
            if (value.nonce.empty())
                return {};
            put_id(out, value.nonce);
        }
        if (value.type == kind::hello)
            return out;
        if (value.type < kind::challenge || value.type > kind::audio_down || value.server.empty())
            return {};
        put_id(out, value.server);
        if (handshake)
        {
            if (value.challenge.empty())
                return {};
            put_id(out, value.challenge);
        }
        if (value.type == kind::challenge || value.type == kind::confirm)
            return out;
        if (value.recipient.empty())
            return {};
        put_id(out, value.recipient);
        if (value.type == kind::heartbeat)
            return out;
        if (value.type == kind::welcome || value.type == kind::roster)
        {
            // Use the same complete-snapshot validation as the receive state.
            state::listener check;
            std::uint32_t changed{};
            check.begin_session(value.server, value.recipient);
            if (value.slot >= state::max_speakers || value.members.server != value.server ||
                value.members.listener != value.recipient ||
                !value.members.speakers[value.slot].present ||
                check.apply_roster(value.members, changed) != state::control_result::applied)
                return {};
            put(out, value.slot, 1);
            put(out, value.members.revision, 8);
            for (const auto& member : value.members.speakers)
            {
                put(out, member.present ? 1 : 0, 1);
                put(out, member.user, 8);
                put_id(out, member.generation);
            }
            return out;
        }
        if (value.type == kind::audio_down)
        {
            if (value.slot >= state::max_speakers || value.generation.empty())
                return {};
            put(out, value.slot, 1);
            put_id(out, value.generation);
        }
        if (value.frames.empty() || value.frames.size() > max_frames)
            return {};
        put(out, value.sequence, 4);
        put(out, value.frames.size(), 1);
        for (const auto& frame : value.frames)
        {
            if (frame.empty() || frame.size() > max_frame_bytes)
                return {};
            put(out, frame.size(), 1);
            out += frame;
        }
        const auto limit = value.type == kind::audio_up
                               ? max_packet_bytes - relay_header_bytes
                               : max_packet_bytes;
        return out.size() <= limit ? out : std::string{};
    }

    inline bool decode(std::string_view data, message& output)
    {
        output = {};
        if (data.size() < 4 || data.size() > max_packet_bytes || data.substr(0, 2) != "IV" ||
            static_cast<unsigned char>(data[2]) != version)
            return false;
        message value;
        value.type = static_cast<kind>(static_cast<unsigned char>(data[3]));
        detail::reader in(data.substr(4));
        std::uint64_t number{};
        if (value.type < kind::hello || value.type > kind::audio_down)
            return false;
        const bool handshake = value.type <= kind::welcome;
        if (handshake && !in.id(value.nonce))
            return false;
        if (value.type != kind::hello)
        {
            if (!in.id(value.server))
                return false;
            if (handshake && !in.id(value.challenge))
                return false;
            if (value.type >= kind::welcome)
            {
                if (!in.id(value.recipient))
                    return false;
                if (value.type == kind::welcome || value.type == kind::roster)
                {
                    if (!in.read(1, number) || number >= state::max_speakers)
                        return false;
                    value.slot = static_cast<unsigned char>(number);
                    value.members.server = value.server;
                    value.members.listener = value.recipient;
                    if (!in.read(8, value.members.revision))
                        return false;
                    for (auto& member : value.members.speakers)
                    {
                        if (!in.read(1, number) || number > 1)
                            return false;
                        member.present = number != 0;
                        if (!in.read(8, member.user) || !in.read(8, member.generation.low) ||
                            !in.read(8, member.generation.high))
                            return false;
                    }
                }
                else if (value.type == kind::audio_up || value.type == kind::audio_down)
                {
                    if (value.type == kind::audio_down)
                    {
                        if (!in.read(1, number) || number >= state::max_speakers ||
                            !in.id(value.generation))
                            return false;
                        value.slot = static_cast<unsigned char>(number);
                    }
                    if (!in.read(4, number))
                        return false;
                    value.sequence = static_cast<std::uint32_t>(number);
                    if (!in.read(1, number) || !number || number > max_frames)
                        return false;
                    const auto count = number;
                    for (unsigned i = 0; i < count; ++i)
                    {
                        if (!in.read(1, number) || !number || number > max_frame_bytes)
                            return false;
                        std::string frame;
                        if (!in.block(static_cast<std::size_t>(number), frame))
                            return false;
                        value.frames.push_back(std::move(frame));
                    }
                }
            }
        }
        // Canonical encoding also rejects invalid/duplicate roster entries and
        // trailing bytes. Failure never publishes a partially decoded message.
        if (!in.done() || encode(value) != data)
            return false;
        output = std::move(value);
        return true;
    }
}
