#pragma once
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace owner_cheats::policy
{
    inline bool hex_token(std::string_view value, std::size_t length)
    {
        if (value.size() != length) return false;
        for (const char c : value)
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        return true;
    }
    inline std::string hex(std::string_view bytes)
    {
        constexpr char digits[] = "0123456789abcdef";
        std::string out; out.reserve(bytes.size() * 2);
        for (const unsigned char c : bytes) { out += digits[c >> 4]; out += digits[c & 15]; }
        return out;
    }
    inline std::string unhex(std::string_view text, std::size_t bytes)
    {
        if (!hex_token(text, bytes * 2)) return {};
        const auto digit = [](char c) { return c <= '9' ? c - '0' : c - 'a' + 10; };
        std::string out(bytes, '\0');
        for (std::size_t i = 0; i < bytes; ++i) out[i] = static_cast<char>((digit(text[2*i]) << 4) | digit(text[2*i+1]));
        return out;
    }
    inline std::vector<std::string> words(std::string_view input)
    {
        std::vector<std::string> out;
        if (input.empty() || input.size() > 512) return out;
        for (const unsigned char c : input) if (c < 32 || c > 126) return {};
        while (!input.empty())
        {
            const auto end = input.find(' ');
            const auto token = input.substr(0, end);
            if (token.empty() || out.size() == 5) return {};
            out.emplace_back(token);
            if (end == std::string_view::npos) break;
            input.remove_prefix(end + 1);
            if (input.empty()) return {};
        }
        return out;
    }
    inline std::string message(char role, std::string_view identity, std::string_view client, std::string_view server)
    {
        return "IW7_OWNER_CHEATS_V1|" + std::string(1, role) + "|" + std::string(identity) + "|" +
            std::string(client) + "|" + std::string(server);
    }
    struct proof
    {
        std::string client, server;
        std::uint64_t expires{}, granted_until{};
        bool used{};
        bool pending(std::string_view c, std::string_view s, std::uint64_t now) const
        { return !used && now < expires && hex_token(c, 64) && hex_token(s, 64) && client == c && server == s; }
        bool consume(std::string_view c, std::string_view s, std::uint64_t now, bool valid)
        {
            if (!pending(c, s, now)) return false;
            used = true;
            if (!valid) { granted_until = 0; return false; }
            granted_until = now + 45000;
            return true;
        }
        bool allowed(std::uint64_t now) const { return used && granted_until != 0 && now < granted_until; }
    };
}
