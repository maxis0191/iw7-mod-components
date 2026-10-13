#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

// Code provenance only. Success grants no input, capture, ARM or audio authority.
// The isolated input owner supplies its real detour tuple and bounded byte copies;
// callers must collect regions BEFORE copying live memory and invoking the getter.
namespace voice_ptt_guard {
inline constexpr std::uintptr_t entry_address = 0x14032A3B0;
inline constexpr std::uintptr_t getter_address = 0x14036FE40;
inline constexpr std::uintptr_t state_address = 0x141FE5B4C;
inline constexpr std::size_t entry_size = 282, patch_size = 5, trampoline_size = 19, relay_size = 14, getter_size = 22, state_size = 20;
inline constexpr unsigned talk_down_binding = 81, talk_up_binding = 82;
inline constexpr unsigned local_client = 0, local_stride = 0x460, active_offset = 0x10;

inline constexpr char retail_entry[] =
    "\x48\x89\x6c\x24\x10\x48\x89\x74\x24\x18\x57\x48\x83\xec\x20\x41\x8b\xe9\x41\x8b\xf8\x8b\xf2\x83\xfa\x51\x75\x6a\x44\x8b\x0d\xed\xaf\xcd\x05\x48\x63\xc1\x48\x69\xc8\x60\x04\x00\x00\x48\x8d\x05\x68\xb7\xcb\x01\x48\x03\xc8\x8b\x11\x44\x3b\xc2\x0f\x84\x16\x11\x00\x00\x8b\x41\x04\x44\x3b\xc0\x0f\x84\x0a\x11\x00\x00\x85\xd2\x75\x05\x44\x89\x01\xeb\x0b\x85\xc0\x0f\x85\xf9\x10\x00\x00\x89\x79\x04\x80\x79\x10\x00\x0f\x85\xec\x10\x00\x00\x44\x89\x49\x08\x66\xc7\x41\x10\x01\x01\x48\x8b\x6c\x24\x38\x48\x8b\x74\x24\x40\x48\x83\xc4\x20\x5f\xc3\x83\xfe\x52\x0f\x85\x8b\x00\x00\x00\x8b\x15\x7b\xaf\xcd\x05\x48\x63\xc1\x48\x69\xc8\x60\x04\x00\x00\x48\x8d\x05\xf6\xb6\xcb\x01\x48\x03\xc8\x8b\x01\x3b\xc7\x75\x08\xc7\x01\x00\x00\x00\x00\xeb\x18\x39\x79\x04\x0f\x85\x98\x10\x00\x00\xc7\x41\x04\x00\x00\x00\x00\x85\xc0\x0f\x85\x89\x10\x00\x00\x83\x79\x04\x00\x0f\x85\x7f\x10\x00\x00\xc6\x41\x10\x00\x85\xd2\x74\x1a\x2b\x51\x08\x01\x51\x0c\xc6\x41\x10\x00\x48\x8b\x6c\x24\x38\x48\x8b\x74\x24\x40\x48\x83\xc4\x20\x5f\xc3\x8b\x05\x8f\xb8\xcb\x01\xd1\xe8\x01\x41\x0c\xc6\x41\x10\x00\x48\x8b\x6c\x24\x38\x48\x8b\x74\x24\x40\x48\x83\xc4\x20\x5f\xc3";
inline constexpr char retail_getter[] = "\x48\x63\xc1\x48\x69\xc8\x60\x04\x00\x00\x48\x8d\x05\x0b\x5d\xc7\x01\x0f\xb6\x04\x01\xc3";
static_assert(sizeof(retail_entry) == entry_size + 1 && sizeof(retail_getter) == getter_size + 1);
static_assert(sizeof(std::uintptr_t) == 8, "Reviewed MinHook shape requires x64");

enum class refusal {
    none, scope, main_thread, output_buffer, owner_not_recorded,
    prehook_address, prehook_region, prehook_bytes, prehook_signature,
    owner_place, owner_original, owner_stub, owner_tuple_changed, address_overflow,
    entry_region, trampoline_region, relay_region, stub_region, getter_region, state_region,
    entry_bytes, trampoline_bytes, relay_bytes, getter_bytes, state_bytes,
    entry_patch_shape, entry_patch_target, trampoline_prefix, trampoline_jump_shape,
    trampoline_jump_target, relay_jump_shape, relay_jump_target, live_body,
    getter_signature, getter_state_target, getter_not_sampled, active_nonboolean, getter_state_mismatch
};
inline const char* name(refusal r) noexcept {
    switch (r) {
    case refusal::none: return "none";
    case refusal::scope: return "scope";
    case refusal::main_thread: return "main_thread";
    case refusal::output_buffer: return "output_buffer";
    case refusal::owner_not_recorded: return "owner_not_recorded";
    case refusal::prehook_address: return "prehook_address";
    case refusal::prehook_region: return "prehook_region";
    case refusal::prehook_bytes: return "prehook_bytes";
    case refusal::prehook_signature: return "prehook_signature";
    case refusal::owner_place: return "owner_place";
    case refusal::owner_original: return "owner_original";
    case refusal::owner_stub: return "owner_stub";
    case refusal::owner_tuple_changed: return "owner_tuple_changed";
    case refusal::address_overflow: return "address_overflow";
    case refusal::entry_region: return "entry_region";
    case refusal::trampoline_region: return "trampoline_region";
    case refusal::relay_region: return "relay_region";
    case refusal::stub_region: return "stub_region";
    case refusal::getter_region: return "getter_region";
    case refusal::state_region: return "state_region";
    case refusal::entry_bytes: return "entry_bytes";
    case refusal::trampoline_bytes: return "trampoline_bytes";
    case refusal::relay_bytes: return "relay_bytes";
    case refusal::getter_bytes: return "getter_bytes";
    case refusal::state_bytes: return "state_bytes";
    case refusal::entry_patch_shape: return "entry_patch_shape";
    case refusal::entry_patch_target: return "entry_patch_target";
    case refusal::trampoline_prefix: return "trampoline_prefix";
    case refusal::trampoline_jump_shape: return "trampoline_jump_shape";
    case refusal::trampoline_jump_target: return "trampoline_jump_target";
    case refusal::relay_jump_shape: return "relay_jump_shape";
    case refusal::relay_jump_target: return "relay_jump_target";
    case refusal::live_body: return "live_body";
    case refusal::getter_signature: return "getter_signature";
    case refusal::getter_state_target: return "getter_state_target";
    case refusal::getter_not_sampled: return "getter_not_sampled";
    case refusal::active_nonboolean: return "active_nonboolean";
    case refusal::getter_state_mismatch: return "getter_state_mismatch";
    }
    return "unknown_refusal";
}
struct region {
    std::uintptr_t base{};
    std::size_t size{};
    bool committed{}, readable{}, executable{}, guarded{}, no_access{};
};
struct bytes {
    std::uintptr_t address{};
    const unsigned char* data{}; // A bounded caller-owned copy, never a remote pointer.
    std::size_t size{};
    region memory{};
};
inline bool add(std::uintptr_t address, std::size_t size, std::uintptr_t& end) noexcept {
    if (size > (std::numeric_limits<std::uintptr_t>::max)() - address) return false;
    end = address + size; return true;
}
inline bool overlaps(std::uintptr_t a, std::size_t a_size, std::uintptr_t b, std::size_t b_size) noexcept {
    std::uintptr_t a_end{}, b_end{};
    return !add(a, a_size, a_end) || !add(b, b_size, b_end) || (a < b_end && b < a_end);
}
inline bool readable(const bytes& b, std::uintptr_t address, std::size_t size, bool code) noexcept {
    std::uintptr_t end{}, region_end{};
    return b.address == address && b.memory.committed && b.memory.readable && !b.memory.guarded && !b.memory.no_access &&
        (!code || b.memory.executable) && b.memory.size && add(address, size, end) && add(b.memory.base, b.memory.size, region_end) &&
        address >= b.memory.base && end <= region_end;
}
inline std::uint32_t u32(const unsigned char* p) noexcept {
    return std::uint32_t(p[0]) | (std::uint32_t(p[1]) << 8) | (std::uint32_t(p[2]) << 16) | (std::uint32_t(p[3]) << 24);
}
inline std::uint64_t u64(const unsigned char* p) noexcept {
    return std::uint64_t(u32(p)) | (std::uint64_t(u32(p + 4)) << 32);
}
inline bool relative_target_after(std::uintptr_t entry, std::size_t width, std::uint32_t displacement, std::uintptr_t& target) noexcept {
    std::uintptr_t next{}; if (!add(entry, width, next)) return false;
    const std::int64_t delta = displacement <= 0x7fffffffU ? std::int64_t(displacement) : std::int64_t(displacement) - 0x100000000LL;
    if (delta < 0) { const auto magnitude = std::uint64_t(-delta); if (magnitude > next) return false; target = next - magnitude; }
    else { if (!add(next, std::size_t(delta), target)) return false; }
    return true;
}
inline bool relative_target(std::uintptr_t entry, std::uint32_t displacement, std::uintptr_t& target) noexcept {
    return relative_target_after(entry, patch_size, displacement, target);
}
inline bool absolute_jump(const unsigned char* p) noexcept {
    return p[0] == 0xff && p[1] == 0x25 && u32(p + 2) == 0;
}
inline refusal validate_before_hook(const bytes& before) noexcept {
    if (before.address != entry_address) return refusal::prehook_address;
    if (!readable(before, entry_address, entry_size, true)) return refusal::prehook_region;
    if (!before.data || before.size != entry_size) return refusal::prehook_bytes;
    if (std::memcmp(before.data, retail_entry, entry_size)) return refusal::prehook_signature;
    return refusal::none;
}
// Captured and privately owned by input.cpp before/at its detour creation.
// Its complete prehook bytes are revalidated on EVERY read, never replaced by a bool.
struct owner {
    std::uintptr_t place{}, original{}, stub{};
    bytes before{};
};
struct observation {
    owner owned{};
    std::uintptr_t observed_place{}, observed_original{}, observed_stub{};
    bytes entry{}, trampoline{}, relay{}, stub{}, getter{}, state{};
    bool getter_sampled{};
    unsigned getter_active{};
};
struct result {
    refusal reason{refusal::none};
    std::uintptr_t relay_target{}, trampoline_target{}, stub_target{}, getter_target{};
    unsigned active{}, getter_active{};
    bool code_validated{};
    bool valid() const noexcept { return reason == refusal::none; }
};
inline result validate_code(const observation& o) noexcept {
    result r;
    const auto fail = [&r](refusal reason) { r.reason = reason; return r; };
    if (o.owned.place != entry_address) return fail(refusal::owner_place);
    if (!o.owned.original || o.owned.original == entry_address || o.owned.original == getter_address) return fail(refusal::owner_original);
    if (!o.owned.stub || o.owned.stub == entry_address || o.owned.stub == getter_address || o.owned.stub == o.owned.original) return fail(refusal::owner_stub);
    if (o.observed_place != o.owned.place || o.observed_original != o.owned.original || o.observed_stub != o.owned.stub) return fail(refusal::owner_tuple_changed);
    const auto before = validate_before_hook(o.owned.before); if (before != refusal::none) return fail(before);
    std::uintptr_t relay{}, back{};
    if (!add(o.owned.original, trampoline_size, relay) || !add(entry_address, patch_size, back)) return fail(refusal::address_overflow);
    std::uintptr_t relay_end{};
    if (!add(relay, relay_size, relay_end)) return fail(refusal::address_overflow);
    if (overlaps(o.owned.original, trampoline_size + relay_size, entry_address, entry_size) ||
        overlaps(o.owned.original, trampoline_size + relay_size, getter_address, getter_size) ||
        overlaps(o.owned.original, trampoline_size + relay_size, state_address, state_size)) return fail(refusal::owner_original);
    if (overlaps(o.owned.stub, 1, o.owned.original, trampoline_size + relay_size) ||
        overlaps(o.owned.stub, 1, entry_address, entry_size) || overlaps(o.owned.stub, 1, getter_address, getter_size) ||
        overlaps(o.owned.stub, 1, state_address, state_size)) return fail(refusal::owner_stub);
    if (!readable(o.entry, entry_address, entry_size, true)) return fail(refusal::entry_region);
    if (!readable(o.trampoline, o.owned.original, trampoline_size, true)) return fail(refusal::trampoline_region);
    if (!readable(o.relay, relay, relay_size, true)) return fail(refusal::relay_region);
    if (!readable(o.stub, o.owned.stub, 1, true)) return fail(refusal::stub_region);
    if (!readable(o.getter, getter_address, getter_size, true)) return fail(refusal::getter_region);
    if (!readable(o.state, state_address, state_size, false)) return fail(refusal::state_region);
    if (!o.entry.data || o.entry.size != entry_size) return fail(refusal::entry_bytes);
    if (!o.trampoline.data || o.trampoline.size != trampoline_size) return fail(refusal::trampoline_bytes);
    if (!o.relay.data || o.relay.size != relay_size) return fail(refusal::relay_bytes);
    if (!o.getter.data || o.getter.size != getter_size) return fail(refusal::getter_bytes);
    if (!o.state.data || o.state.size != state_size) return fail(refusal::state_bytes);
    if (o.entry.data[0] != 0xe9) return fail(refusal::entry_patch_shape);
    if (!relative_target(entry_address, u32(o.entry.data + 1), r.relay_target)) return fail(refusal::address_overflow);
    if (r.relay_target != relay) return fail(refusal::entry_patch_target);
    if (std::memcmp(o.trampoline.data, retail_entry, patch_size)) return fail(refusal::trampoline_prefix);
    if (!absolute_jump(o.trampoline.data + patch_size)) return fail(refusal::trampoline_jump_shape);
    r.trampoline_target = u64(o.trampoline.data + patch_size + 6);
    if (r.trampoline_target != back) return fail(refusal::trampoline_jump_target);
    if (!absolute_jump(o.relay.data)) return fail(refusal::relay_jump_shape);
    r.stub_target = u64(o.relay.data + 6);
    if (r.stub_target != o.owned.stub) return fail(refusal::relay_jump_target);
    if (std::memcmp(o.entry.data + patch_size, retail_entry + patch_size, entry_size - patch_size)) return fail(refusal::live_body);
    if (std::memcmp(o.getter.data, retail_getter, getter_size)) return fail(refusal::getter_signature);
    std::uintptr_t active_address{};
    if (!relative_target_after(getter_address, 17, u32(o.getter.data + 13), r.getter_target) ||
        !add(state_address, active_offset, active_address)) return fail(refusal::address_overflow);
    if (r.getter_target != active_address) return fail(refusal::getter_state_target);
    r.code_validated = true; return r;
}
// The adapter may invoke the retail getter(0) only after validate_code succeeds.
// It must retain the same main-thread observation and call this final gate.
inline result validate(const observation& o) noexcept {
    auto r = validate_code(o);
    if (!r.valid()) return r;
    if (!readable(o.state, state_address, state_size, false)) { r.reason = refusal::state_region; return r; }
    if (!o.state.data || o.state.size != state_size) { r.reason = refusal::state_bytes; return r; }
    if (!o.getter_sampled) { r.reason = refusal::getter_not_sampled; return r; }
    r.active = o.state.data[active_offset];
    r.getter_active = o.getter_active;
    if (r.active > 1 || o.getter_active > 1) { r.reason = refusal::active_nonboolean; return r; }
    if (o.getter_active != r.active) { r.reason = refusal::getter_state_mismatch; return r; }
    return r;
}
#ifdef IW7_PARIS_ISOLATED_PTT_INPUT_BRIDGE
// Defined only by the scoped transform of the real input.cpp owner. This reads
// the local retail state; it never dispatches a key or acquires an audio device.
result input_snapshot(unsigned char* destination, std::size_t size, unsigned long main_thread);
#endif
}
