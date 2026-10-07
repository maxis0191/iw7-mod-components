#pragma once
namespace paris_voice_test_capture {
void install();
void relay_main_tick() noexcept;
void cancel() noexcept;
bool talk_admitted() noexcept;
}
