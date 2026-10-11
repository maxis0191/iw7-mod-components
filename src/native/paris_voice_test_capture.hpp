#pragma once
#include <cstdint>
namespace paris_voice_test_capture {
void install();
void relay_main_tick() noexcept;
void cancel() noexcept;
bool talk_admitted() noexcept;
bool begin_source_after_native_talk(std::uint64_t tick) noexcept;
}
