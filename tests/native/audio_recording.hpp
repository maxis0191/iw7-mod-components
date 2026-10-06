#pragma once
#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <limits>
#include <vector>
#include <utility>
#include <unordered_map>
#include <unordered_set>

namespace audio_recording
{
inline std::size_t descendants(const std::vector<std::pair<std::uint32_t, std::uint32_t>>& rows, std::uint32_t root)
{
    if (rows.size() > 16384 || !root) throw std::runtime_error("Process inventory bound exceeded");
    std::unordered_multimap<std::uint32_t, std::uint32_t> children;
    std::unordered_set<std::uint32_t> unique, visited{root};
    for (const auto& row : rows)
    {
        if (!unique.insert(row.first).second) throw std::runtime_error("Ambiguous process inventory");
        children.emplace(row.second, row.first);
    }
    std::vector<std::uint32_t> pending{root};
    for (std::size_t i = 0; i < pending.size(); ++i)
    {
        const auto range = children.equal_range(pending[i]);
        for (auto next = range.first; next != range.second; ++next)
        {
            if (!visited.insert(next->second).second) throw std::runtime_error("Process descendant cycle");
            pending.push_back(next->second);
        }
    }
    return pending.size() - 1;
}
inline std::uint64_t decimal(const std::string& value)
{
    if (value.empty()) throw std::runtime_error("Missing decimal argument");
    std::uint64_t result{};
    for (const char c : value)
    {
        if (c < '0' || c > '9' || result > (std::numeric_limits<std::uint64_t>::max() - (c - '0')) / 10)
            throw std::runtime_error("Invalid decimal argument");
        result = result * 10 + (c - '0');
    }
    return result;
}
struct request
{
    unsigned seconds;
    std::uint32_t pid;
    std::uint64_t creation;
    std::string image, hash, output;
};
inline request parse(int argc, char** argv)
{
    if (argc != 8 || std::string(argv[1]) != "--record")
        throw std::runtime_error("Usage: --record seconds PID creation_FILETIME full_image SHA256 fresh_output.wav");
    const auto seconds = decimal(argv[2]), pid = decimal(argv[3]), creation = decimal(argv[4]);
    if (!seconds || seconds > 60 || !pid || pid > UINT32_MAX || !creation)
        throw std::runtime_error("Recording requires 1..60 seconds and exact nonzero PID/creation");
    const std::string image(argv[5]), hash(argv[6]), output(argv[7]);
    if (image.empty() || output.empty() || hash.size() != 64)
        throw std::runtime_error("Image, SHA256 and fresh WAV path required");
    for (char c : hash)
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')))
            throw std::runtime_error("Invalid SHA256");
    return {static_cast<unsigned>(seconds), static_cast<std::uint32_t>(pid), creation, image, hash, output};
}
inline std::array<unsigned char, 44> header(std::uint32_t bytes)
{
    if (bytes > 60u * 192000 || bytes % 4) throw std::runtime_error("WAV exceeds frame/duration bound");
    std::array<unsigned char, 44> result{};
    auto u16 = [&](unsigned offset, std::uint16_t value) {
        result[offset] = static_cast<unsigned char>(value); result[offset + 1] = static_cast<unsigned char>(value >> 8);
    };
    auto u32 = [&](unsigned offset, std::uint32_t value) {
        for (unsigned i = 0; i < 4; ++i) result[offset + i] = static_cast<unsigned char>(value >> (8 * i));
    };
    const char* riff = "RIFF"; const char* wave = "WAVEfmt "; const char* data = "data";
    for (unsigned i = 0; i < 4; ++i) { result[i] = riff[i]; result[36 + i] = data[i]; }
    for (unsigned i = 0; i < 8; ++i) result[8 + i] = wave[i];
    u32(4, bytes + 36); u32(16, 16); u16(20, 1); u16(22, 2);
    u32(24, 48000); u32(28, 192000); u16(32, 4); u16(34, 16); u32(40, bytes);
    return result;
}
}
