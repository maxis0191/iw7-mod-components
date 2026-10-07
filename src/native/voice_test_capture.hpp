#pragma once
// Standalone candidate: not installed in the shipping or isolated component yet.
#include <windows.h>
#include <mmreg.h>
#include <dsound.h>
#include <cstdint>
#include <string>
#include <vector>
#include <memory>

namespace voice_test_capture
{
struct admission
{
    bool requested{}, isolated_build{}, isolated_flag{}, client_test_flag{}, voice_test_flag{};
    bool marker_verified{}, owned_identity{}, signatures_verified{}, capture_owner_absent{}, volume_owner_absent{};
    unsigned server_port{}, process_id{}, slot{};
    std::string client_nonce, server_generation, source_sha256;
    std::uint64_t admitted_tick{}, deadline_tick{};
};
// Callbacks must not reenter this COM/control object. Callback must validate the same retained PID/nonce/generation/port, active
// connection and engine protection, at most 500ms old. No endpoint API involved.
struct environment
{
    void* opaque{};
    // prepare() owns this provider until the last COM/control reference dies.
    std::shared_ptr<void> owner;
    std::uint64_t (*now)(void*) noexcept{};
    bool (*fresh)(void*, const admission&, std::uint64_t) noexcept{};
};
struct statistics
{
    bool prepared{}, armed{}, failed{}, buffer_created{}, buffer_started{}, buffer_locked{};
    unsigned descriptor_bytes{}, descriptor_flags{}, rate{}, channels{}, bits{}, block_align{}, buffer_bytes{};
    std::uint64_t source_frames{}, published_frames{}, published_source_frames{}, published_nonzero_frames{};
    std::uint64_t lock_calls{}, lock_bytes{}, lock_nonzero_bytes{}, prepared_lock_bytes{}, unlock_calls{}, unlock_bytes{};
};
class control
{
public:
    virtual ~control() = default;
    virtual HRESULT arm(const admission&) noexcept = 0;
    virtual void cancel() noexcept = 0;
    // Copies observations under the shared buffer mutex. Does not sample the
    // clock, refresh protection, advance a cursor or alter the state machine.
    virtual statistics snapshot() noexcept = 0;
};
// Separate preparation policy: empty nonce/generation, same explicit lab scope,
// no WAV publication, and at most 120 seconds to acquire a protected connection.
// Start succeeds; cursor remains zero. An outstanding Lock prevents arm.
HRESULT prepare(const admission& preparation_scope, const environment&,
    const std::vector<unsigned char>& wav, IDirectSoundCapture** output,
    std::shared_ptr<control>* controller) noexcept;
bool permitted(const admission&, std::uint64_t now) noexcept;
// Exact source bytes are hashed here and parsed once. Caller retains its source
// file identity while reading these bounded bytes; no paths or device fallbacks.
HRESULT create(const admission&, const environment&, const std::vector<unsigned char>& wav,
    IDirectSoundCapture** output) noexcept;
}
