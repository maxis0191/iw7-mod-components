#pragma once
#include <cstdint>
namespace paris_voice_test_capture {
void install();
void relay_main_tick() noexcept;
void cancel() noexcept;
bool talk_admitted() noexcept;
bool begin_source_after_native_talk(std::uint64_t tick) noexcept;
void observe_native_encoder() noexcept;
// Forward the exact accepted v2 frame; the optional lab tap copies only native
// decoder/enqueue output during this synchronous call, never fixture source PCM.
void received_playback(void* session,unsigned slot,const char* data,int bytes,
    std::uint64_t user,std::uint64_t epoch_low,std::uint64_t epoch_high,
    std::uint32_t sequence,unsigned frame_index);
}
