#pragma once
#include <cstdint>
#include <string>
#include <vector>

// In-memory evidence only. The caller supplies the actual native decoder output,
// accepted enqueue length and a freshly observed protection predicate.
namespace voice_pcm_witness {
struct scope {
    std::uint32_t pid{};
    unsigned receiver_slot{}, sender_slot{};
    std::string nonce, generation, challenge;
    std::uint64_t admitted_tick{}, deadline_tick{};
};
struct speaker {
    unsigned slot{};
    std::uint64_t user{}, epoch_low{}, epoch_high{};
    std::uint32_t sequence{};
    unsigned frame_index{};
};
struct frame {
    int samples{};
    std::vector<std::int16_t> decoded;
    int enqueued_bytes{};
};
inline bool valid_id(const std::string& value) {
    return value.size()==32 && value.find_first_not_of("0123456789abcdef")==std::string::npos &&
        value.find_first_not_of('0')!=std::string::npos;
}
class buffer {
public:
    static constexpr std::uint64_t byte_limit=256*1024;
private:
    scope scope_;
    speaker identity_{};
    bool failed_{}, bound_{};
    std::uint64_t last_tick_{}, frames_{}, truncated_{};
    std::vector<std::int16_t> decoded_, submitted_;
    bool refuse() noexcept { failed_=true; return false; }
public:
    explicit buffer(const scope& value) : scope_(value), last_tick_(value.admitted_tick) {
        if(!value.pid || value.receiver_slot>1 || value.sender_slot>1 || value.receiver_slot==value.sender_slot ||
            !valid_id(value.nonce) || !valid_id(value.generation) || !valid_id(value.challenge) ||
            !value.admitted_tick || value.deadline_tick<=value.admitted_tick ||
            value.deadline_tick-value.admitted_tick>15000) { failed_=true; return; }
        // Avoid allocations in the native forwarding callbacks. Both bounds are
        // independent, and storage never grows beyond these fixed reservations.
        decoded_.reserve(byte_limit/sizeof(std::int16_t));
        submitted_.reserve(byte_limit/sizeof(std::int16_t));
    }
    bool append(const speaker& source,const frame& pcm,std::uint64_t now,bool protection_fresh) {
        if(failed_) return false;
        if(!protection_fresh || now<scope_.admitted_tick || now<last_tick_ || now>=scope_.deadline_tick ||
            source.slot!=scope_.sender_slot || !source.user || (!source.epoch_low && !source.epoch_high) ||
            (bound_ && (source.slot!=identity_.slot || source.user!=identity_.user ||
                source.epoch_low!=identity_.epoch_low || source.epoch_high!=identity_.epoch_high)) ||
            pcm.samples<1 || pcm.samples>4096 || pcm.decoded.size()!=static_cast<std::size_t>(pcm.samples) ||
            pcm.enqueued_bytes<0 || (pcm.enqueued_bytes%2)!=0) return refuse();
        const auto bytes=static_cast<std::uint64_t>(pcm.samples)*sizeof(std::int16_t);
        const auto accepted=static_cast<std::uint64_t>(pcm.enqueued_bytes);
        if(accepted>bytes || bytes>byte_limit-decoded_bytes() || accepted>byte_limit-enqueued_bytes()) return refuse();
        decoded_.insert(decoded_.end(),pcm.decoded.begin(),pcm.decoded.end());
        submitted_.insert(submitted_.end(),pcm.decoded.begin(),pcm.decoded.begin()+pcm.enqueued_bytes/2);
        if(!bound_) { identity_=source; bound_=true; }
        last_tick_=now; ++frames_;
        if(accepted<bytes) ++truncated_;
        return true;
    }
    bool failed() const noexcept { return failed_; }
    // A watchdog can revoke further collection without destroying diagnostics.
    void invalidate() noexcept { failed_=true; }
    const std::vector<std::int16_t>& decoded() const noexcept { return decoded_; }
    const std::vector<std::int16_t>& submitted() const noexcept { return submitted_; }
    std::uint64_t frames() const noexcept { return frames_; }
    std::uint64_t decoded_bytes() const noexcept { return decoded_.size()*sizeof(std::int16_t); }
    std::uint64_t enqueued_bytes() const noexcept { return submitted_.size()*sizeof(std::int16_t); }
    std::uint64_t truncated_frames() const noexcept { return truncated_; }
    // Null before the first accepted frame; sequence/frame_index describe that
    // first observation, while user/epoch/slot remain the pinned incarnation.
    const speaker* speaker_identity() const noexcept { return bound_ ? &identity_ : nullptr; }
};
}
