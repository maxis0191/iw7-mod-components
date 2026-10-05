#include "../../src/native/voice_relay.hpp"
#include <iostream>
#include <stdexcept>

int main()
{
    const std::vector<std::string> expected{"noupdate", "nosteam", "cpMode", "iw7-voice-relay"};
    for (const auto* path : {"iw7-paris-voice.exe", "C:\\Game With Spaces\\IW7-PARIS-VOICE.EXE"})
    {
        std::vector<std::string> flags;
        voice_relay::apply_player_defaults(path, 1, flags);
        if (flags != expected) throw std::runtime_error("Bare player launch lacks v2 defaults");
    }
    for (const auto* path : {"iw7-mod.exe", "iw7-paris-lab.exe", "iw7-paris-voice.exe.backup"})
    {
        std::vector<std::string> flags;
        voice_relay::apply_player_defaults(path, 1, flags);
        if (!flags.empty()) throw std::runtime_error("Unrelated binary was changed");
    }
    for (int argc : {0, 2, 5})
    {
        std::vector<std::string> flags{"mpMode"};
        voice_relay::apply_player_defaults("iw7-paris-voice.exe", argc, flags);
        if (flags != std::vector<std::string>{"mpMode"})
            throw std::runtime_error("Explicit launch arguments were changed");
    }
    std::cout << "PASS: bare named player defaults and unrelated/explicit launch preservation\n";
}
