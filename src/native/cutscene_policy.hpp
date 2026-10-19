#pragma once
#include <array>
#include <cstdint>
#include <string>

namespace iw7::cutscene {
struct voter {
    std::string identity;
    bool voted{};
    unsigned released{};
    std::array<std::uint64_t, 3> since{};
};
struct ballot {
    std::array<voter, 4> players{};
    void roster(unsigned slot, const std::string& identity) {
        if (slot < players.size() && players[slot].identity != identity) players[slot] = {identity};
    }
    void input(unsigned slot, unsigned mask, std::uint64_t now) {
        if (slot >= players.size()) return;
        auto& p = players[slot];
        if (p.identity.empty() || p.voted) return;
        for (unsigned key = 0; key < 3; ++key) {
            const auto bit = 1u << key;
            if (!(mask & bit)) { p.since[key] = 0; p.released |= bit; }
            else if (p.released & bit) {
                if (!p.since[key]) p.since[key] = now;
                else if (now >= p.since[key] && now - p.since[key] >= 2000) p.voted = true;
            }
        }
    }
    unsigned total() const { unsigned n{}; for (const auto& p : players) n += !p.identity.empty(); return n; }
    unsigned votes() const { unsigned n{}; for (const auto& p : players) n += !p.identity.empty() && p.voted; return n; }
    bool unanimous() const { return total() && votes() == total(); }
};
// This bytecode borrows the existing frame. Builtin1 consumes the original
// OP_wait operand; both builtin results are consumed. The final byte is a
// redirect sentinel, avoiding any pointer-distance assumption for retail code.
inline std::array<unsigned char, 20> wait_thunk(std::uint16_t begin, std::uint16_t pending) {
    return {0x1b, static_cast<unsigned char>(begin), static_cast<unsigned char>(begin >> 8), 0x69,
        0x1a, static_cast<unsigned char>(pending), static_cast<unsigned char>(pending >> 8),
        0xaf, 9, 0, 0x2b, 0xcd, 0xcc, 0x4c, 0x3d, 0x79, 0x91, 15, 0, 0x34};
}
}
