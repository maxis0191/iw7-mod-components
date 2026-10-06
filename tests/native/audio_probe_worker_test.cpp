// Non-audio worker used to test the recorder watchdog and malformed-output gate.
#define NOMINMAX
#include <windows.h>
#include <fstream>
#include <string>
#include "audio_recording.hpp"
int main(int argc, char** argv)
{
    if (argc == 2 && std::string(argv[1]) == "--sleep") { Sleep(5000); return 0; }
    if (argc != 8 || std::string(argv[1]) != "--record") return 2;
    auto header = audio_recording::header(4);
    std::ofstream file(argv[7], std::ios::binary);
    file.write(reinterpret_cast<const char*>(header.data()), header.size());
    if (std::string(argv[2]) == "1") { const char silence[4]{}; file.write(silence,4); }
    // seconds=2 exits zero with a deliberately truncated PCM payload.
    return file.good() ? 0 : 3;
}
