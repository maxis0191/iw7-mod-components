#include "voice_ptt_guard.hpp"
#include <array>
#include <iostream>
#include <stdexcept>
#include <string>

namespace guard = voice_ptt_guard;
namespace
{
    unsigned checks{};
    void check(bool value, const char* description)
    {
        ++checks;
        if (!value) throw std::runtime_error(description);
    }
    void write32(unsigned char* out, std::uint32_t value)
    {
        for (unsigned i = 0; i != 4; ++i) out[i] = static_cast<unsigned char>(value >> (8 * i));
    }
    void write64(unsigned char* out, std::uint64_t value)
    {
        for (unsigned i = 0; i != 8; ++i) out[i] = static_cast<unsigned char>(value >> (8 * i));
    }
    void jump(unsigned char* out, std::uintptr_t target)
    {
        out[0] = 0xff; out[1] = 0x25; write32(out + 2, 0); write64(out + 6, target);
    }
    guard::region code(std::uintptr_t address, std::size_t size) { return {address, size, true, true, true, false, false}; }
    struct fixture
    {
        std::uintptr_t original{0x14040A000}, stub{0x18002C000};
        std::array<unsigned char, guard::entry_size> before{}, entry{};
        std::array<unsigned char, guard::trampoline_size> trampoline{};
        std::array<unsigned char, guard::relay_size> relay{};
        std::array<unsigned char, guard::getter_size> getter{};
        std::array<unsigned char, guard::state_size> state{};
        fixture()
        {
            std::memcpy(before.data(), guard::retail_entry, before.size());
            std::memcpy(entry.data(), guard::retail_entry, entry.size());
            std::memcpy(trampoline.data(), guard::retail_entry, guard::patch_size);
            std::memcpy(getter.data(), guard::retail_getter, getter.size());
            set_original(original);
            state[guard::active_offset] = 1;
        }
        void set_original(std::uintptr_t value)
        {
            original = value;
            entry[0] = 0xe9;
            const auto delta = static_cast<std::int64_t>(original + guard::trampoline_size) -
                static_cast<std::int64_t>(guard::entry_address + guard::patch_size);
            write32(entry.data() + 1, static_cast<std::uint32_t>(delta));
            jump(trampoline.data() + guard::patch_size, guard::entry_address + guard::patch_size);
            jump(relay.data(), stub);
        }
        guard::observation sample()
        {
            guard::observation o;
            o.owned = {guard::entry_address, original, stub,
                {guard::entry_address, before.data(), before.size(), code(guard::entry_address, before.size())}};
            o.observed_place = guard::entry_address; o.observed_original = original; o.observed_stub = stub;
            o.entry = {guard::entry_address, entry.data(), entry.size(), code(guard::entry_address, entry.size())};
            o.trampoline = {original, trampoline.data(), trampoline.size(), code(original, trampoline.size())};
            o.relay = {original + guard::trampoline_size, relay.data(), relay.size(), code(original + guard::trampoline_size, relay.size())};
            o.stub = {stub, nullptr, 0, code(stub, 1)};
            o.getter = {guard::getter_address, getter.data(), getter.size(), code(guard::getter_address, getter.size())};
            o.state = {guard::state_address, state.data(), state.size(), {guard::state_address, state.size(), true, true, false, false, false}};
            o.getter_sampled = true; o.getter_active = state[guard::active_offset];
            return o;
        }
    };
    void expect(const guard::observation& observation, guard::refusal reason)
    {
        const auto actual = guard::validate(observation);
        if (actual.reason != reason)
            throw std::runtime_error(std::string("Expected ") + guard::name(reason) + "; got " + guard::name(actual.reason));
        check(!actual.valid(), "A named refusal must remain invalid");
        check(std::string(guard::name(actual.reason)) != "unknown_refusal", "Refusal must have a stable diagnostic name");
    }
    template <typename Change>
    void altered(Change change, guard::refusal reason)
    {
        fixture f; auto o = f.sample(); change(f, o); expect(o, reason);
    }
}
int main()
{
    fixture f; auto o = f.sample(); auto proof = guard::validate(o);
    check(proof.valid() && proof.code_validated && proof.active == 1 && proof.getter_active == 1, "Exact owner chain and active getter must pass");
    check(proof.relay_target == f.original + 19 && proof.trampoline_target == guard::entry_address + 5 &&
        proof.stub_target == f.stub && proof.getter_target == guard::state_address + 16, "Targets must correlate with the actual owner and data offset");
    f.state[guard::active_offset] = 0; check(guard::validate(f.sample()).valid(), "Released retail key must pass");
    f.set_original(guard::entry_address - 0x100000); check(guard::validate(f.sample()).valid(), "Owned negative rel32 patch must pass");
    f.state[0] = 224; f.state[4] = 86; check(guard::validate(f.sample()).valid(), "Provenance must not clear or reinterpret held physical keys");

    altered([](auto&, auto& x) { ++x.owned.before.address; }, guard::refusal::prehook_address);
    altered([](auto&, auto& x) { x.owned.before.memory.readable = false; }, guard::refusal::prehook_region);
    altered([](auto&, auto& x) { x.owned.before.size = 281; }, guard::refusal::prehook_bytes);
    altered([](auto& x, auto&) { x.before[0] ^= 1; }, guard::refusal::prehook_signature);
    altered([](auto& x, auto&) { x.before[281] ^= 1; }, guard::refusal::prehook_signature);
    altered([](auto&, auto& x) { x.owned.place = guard::getter_address; }, guard::refusal::owner_place);
    altered([](auto&, auto& x) { x.owned.original = 0; }, guard::refusal::owner_original);
    altered([](auto&, auto& x) { x.owned.stub = 0; }, guard::refusal::owner_stub);
    altered([](auto&, auto& x) { ++x.observed_place; }, guard::refusal::owner_tuple_changed);
    altered([](auto&, auto& x) { ++x.observed_original; }, guard::refusal::owner_tuple_changed);
    altered([](auto&, auto& x) { ++x.observed_stub; }, guard::refusal::owner_tuple_changed);
    altered([](auto&, auto& x) { x.owned.original = x.observed_original = guard::entry_address + 10; }, guard::refusal::owner_original);
    altered([](auto&, auto& x) { x.owned.stub = x.observed_stub = x.owned.original + 19; }, guard::refusal::owner_stub);
    altered([](auto&, auto& x) { x.owned.original = x.observed_original = std::numeric_limits<std::uintptr_t>::max() - 10; }, guard::refusal::address_overflow);
    altered([](auto&, auto& x) { x.owned.original = x.observed_original = std::numeric_limits<std::uintptr_t>::max() - 25; }, guard::refusal::address_overflow);

    altered([](auto&, auto& x) { x.entry.memory.committed = false; }, guard::refusal::entry_region);
    altered([](auto&, auto& x) { x.entry.memory.executable = false; }, guard::refusal::entry_region);
    altered([](auto&, auto& x) { --x.entry.memory.size; }, guard::refusal::entry_region);
    altered([](auto&, auto& x) { ++x.entry.memory.base; }, guard::refusal::entry_region);
    altered([](auto&, auto& x) { x.entry.memory.base = std::numeric_limits<std::uintptr_t>::max() - 2; x.entry.memory.size = 10; }, guard::refusal::entry_region);
    altered([](auto&, auto& x) { x.trampoline.memory.guarded = true; }, guard::refusal::trampoline_region);
    altered([](auto&, auto& x) { --x.trampoline.memory.size; }, guard::refusal::trampoline_region);
    altered([](auto&, auto& x) { x.relay.memory.no_access = true; }, guard::refusal::relay_region);
    altered([](auto&, auto& x) { x.relay.memory.executable = false; }, guard::refusal::relay_region);
    altered([](auto&, auto& x) { x.stub.memory.executable = false; }, guard::refusal::stub_region);
    altered([](auto&, auto& x) { x.getter.memory.readable = false; }, guard::refusal::getter_region);
    altered([](auto&, auto& x) { --x.getter.memory.size; }, guard::refusal::getter_region);
    altered([](auto&, auto& x) { x.state.memory.guarded = true; }, guard::refusal::state_region);
    altered([](auto&, auto& x) { x.state.memory.committed = false; }, guard::refusal::state_region);
    altered([](auto&, auto& x) { --x.state.memory.size; }, guard::refusal::state_region);
    // validate_code is the pre-invocation gate too: unsafe state must prevent
    // even a getter call, rather than failing after it already read memory.
    o = f.sample(); o.state.memory.readable = false;
    check(guard::validate_code(o).reason == guard::refusal::state_region && !guard::validate_code(o).code_validated, "Unreadable state must refuse before getter invocation");
    altered([](auto&, auto& x) { x.entry.data = nullptr; }, guard::refusal::entry_bytes);
    altered([](auto&, auto& x) { ++x.trampoline.size; }, guard::refusal::trampoline_bytes);
    altered([](auto&, auto& x) { x.relay.data = nullptr; }, guard::refusal::relay_bytes);
    altered([](auto&, auto& x) { --x.getter.size; }, guard::refusal::getter_bytes);
    altered([](auto&, auto& x) { x.state.data = nullptr; }, guard::refusal::state_bytes);

    altered([](auto& x, auto&) { x.entry[0] = 0xeb; }, guard::refusal::entry_patch_shape);
    altered([](auto& x, auto&) { ++x.entry[1]; }, guard::refusal::entry_patch_target);
    altered([](auto& x, auto&) { x.trampoline[0] ^= 1; }, guard::refusal::trampoline_prefix);
    altered([](auto& x, auto&) { x.trampoline[5] = 0xe9; }, guard::refusal::trampoline_jump_shape);
    altered([](auto& x, auto&) { x.trampoline[7] = 1; }, guard::refusal::trampoline_jump_shape);
    altered([](auto& x, auto&) { ++x.trampoline[11]; }, guard::refusal::trampoline_jump_target);
    altered([](auto& x, auto&) { x.relay[1] = 0x15; }, guard::refusal::relay_jump_shape);
    altered([](auto& x, auto&) { x.relay[2] = 1; }, guard::refusal::relay_jump_shape);
    altered([](auto& x, auto&) { ++x.relay[6]; }, guard::refusal::relay_jump_target);
    // Reject a different E9 destination even when it uses a perfectly formed
    // foreign relay/trampoline. MinHook-shaped bytes alone are no ownership.
    altered([](auto& x, auto&) { write32(x.entry.data() + 1, 0); }, guard::refusal::entry_patch_target);
    for (std::size_t i = guard::patch_size; i != guard::entry_size; ++i)
        altered([i](auto& x, auto&) { x.entry[i] ^= 1; }, guard::refusal::live_body);
    for (std::size_t i = 0; i != guard::getter_size; ++i)
        altered([i](auto& x, auto&) { x.getter[i] ^= 1; }, guard::refusal::getter_signature);
    altered([](auto&, auto& x) { x.getter_sampled = false; }, guard::refusal::getter_not_sampled);
    altered([](auto& x, auto&) { x.state[guard::active_offset] = 2; }, guard::refusal::active_nonboolean);
    altered([](auto&, auto& x) { x.getter_active = 2; }, guard::refusal::active_nonboolean);
    altered([](auto&, auto& x) { x.getter_active = 0; }, guard::refusal::getter_state_mismatch);

    std::uintptr_t target{};
    check(guard::relative_target(100, 0xfffffffbU, target) && target == 100, "Signed negative rel32 decode");
    check(!guard::relative_target(0, 0x80000000U, target), "Signed rel32 underflow must refuse");
    check(!guard::relative_target(std::numeric_limits<std::uintptr_t>::max() - 2, 0, target), "Entry+5 overflow must refuse");
    check(!guard::relative_target(std::numeric_limits<std::uintptr_t>::max() - 10, 100, target), "Positive rel32 overflow must refuse");
    check(guard::talk_down_binding == 81 && guard::talk_up_binding == 82 && guard::local_client == 0 &&
        guard::local_stride == 0x460 && guard::active_offset == 16, "Retail PTT contract must remain fixed");
    std::cout << "PASS " << checks << " exact owned MinHook PTT provenance checks; no engine/input/audio calls.\n";
}
