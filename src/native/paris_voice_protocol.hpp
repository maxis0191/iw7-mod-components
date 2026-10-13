#pragma once
#include <array>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

// Versioned, bounded UDP payload. No engine pointers or player identifiers on wire.
namespace paris_voice::protocol
{
    constexpr unsigned version = 1;
    constexpr unsigned slots = 18;
    constexpr unsigned max_frames = 10;
    constexpr unsigned max_frame_bytes = 254;
    constexpr unsigned max_packet_bytes = 1200;
    enum class kind : unsigned char { hello = 1, ready = 2, audio = 3, probe = 4 };
    struct packet
    {
        kind type{};
        std::uint64_t token{}; // hello challenge, or server-issued endpoint capability
        std::uint64_t challenge{}; // ready echoes hello challenge
        std::uint32_t sequence{};
        unsigned char speaker{};
        std::vector<std::string> frames;
    };
    inline void put(std::string& out, std::uint64_t value, unsigned bytes)
    {
        for (unsigned i = 0; i < bytes; ++i) out.push_back(static_cast<char>(value >> (i * 8)));
    }
    inline bool read(std::string_view in, std::size_t& pos, unsigned bytes, std::uint64_t& value)
    {
        if (pos > in.size() || bytes > in.size() - pos) return false;
        value = 0;
        for (unsigned i = 0; i < bytes; ++i) value |= std::uint64_t(static_cast<unsigned char>(in[pos++])) << (i * 8);
        return true;
    }
    inline std::string encode(const packet& p)
    {
        std::string out("PV", 2);
        put(out, version, 1); put(out, static_cast<unsigned char>(p.type), 1); put(out, p.token, 8);
        if (!p.token) return {};
        if (p.type == kind::hello) return out;
        if (p.type == kind::ready)
        {
            if (!p.challenge || p.speaker >= slots) return {};
            put(out, p.challenge, 8); put(out, p.speaker, 1); return out;
        }
        if ((p.type != kind::audio && p.type != kind::probe) || p.speaker >= slots || p.frames.empty() || p.frames.size() > max_frames) return {};
        put(out, p.sequence, 4); put(out, p.speaker, 1); put(out, p.frames.size(), 1);
        for (const auto& f : p.frames)
        {
            if (f.empty() || f.size() > max_frame_bytes) return {};
            put(out, f.size(), 1); out += f;
        }
        return out.size() <= max_packet_bytes ? out : std::string{};
    }
    inline bool decode(std::string_view in, packet& out)
    {
        out = {};
        if (in.size() < 12 || in.size() > max_packet_bytes || in.substr(0, 2) != "PV" ||
            static_cast<unsigned char>(in[2]) != version) return false;
        out.type = static_cast<kind>(in[3]);
        std::size_t pos = 4; std::uint64_t value{};
        if (!read(in, pos, 8, out.token) || !out.token) return false;
        if (out.type == kind::hello) return pos == in.size();
        if (out.type == kind::ready)
        {
            if (!read(in, pos, 8, out.challenge) || !out.challenge || !read(in, pos, 1, value) || value >= slots) return false;
            out.speaker = static_cast<unsigned char>(value); return pos == in.size();
        }
        if ((out.type != kind::audio && out.type != kind::probe) || !read(in, pos, 4, value)) return false;
        out.sequence = static_cast<std::uint32_t>(value);
        if (!read(in, pos, 1, value) || value >= slots) return false;
        out.speaker = static_cast<unsigned char>(value);
        if (!read(in, pos, 1, value) || !value || value > max_frames) return false;
        const auto count = value;
        for (unsigned i = 0; i < count; ++i)
        {
            if (!read(in, pos, 1, value) || !value || value > max_frame_bytes || value > in.size() - pos) return false;
            out.frames.emplace_back(in.substr(pos, static_cast<std::size_t>(value))); pos += static_cast<std::size_t>(value);
        }
        return pos == in.size();
    }
    // Half-range comparison handles uint32 wrap and rejects duplicates/backwards packets.
    struct replay_window
    {
        bool initialized{}; std::uint32_t last{};
        bool accept(std::uint32_t seq)
        {
            if (initialized && (seq == last || static_cast<std::uint32_t>(seq - last) >= 0x80000000u)) return false;
            initialized = true; last = seq; return true;
        }
    };
    struct rate_limit
    {
        double frames = 100, bytes = 24000; std::uint64_t last_ms{};
        bool accept(unsigned frame_count, unsigned byte_count, std::uint64_t now_ms)
        {
            const double elapsed = now_ms >= last_ms ? static_cast<double>(now_ms - last_ms) / 1000 : 0;
            last_ms = now_ms;
            frames = (frames + elapsed * 60 < 100) ? frames + elapsed * 60 : 100;
            bytes = (bytes + elapsed * 16000 < 24000) ? bytes + elapsed * 16000 : 24000;
            if (frames < frame_count || bytes < byte_count) return false;
            frames -= frame_count; bytes -= byte_count; return true;
        }
    };
}
