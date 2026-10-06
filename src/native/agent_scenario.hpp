#pragma once
#include <array>
#include <algorithm>
#include <charconv>
#include <cstdint>
#include <cstddef>
#include <memory>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>
#include <type_traits>
#include <limits>

namespace iw7::agent
{
    enum class button : unsigned { forward, back, left, right, jump, melee, use, reload, ads, fire,
        aim_left, aim_right, aim_up, aim_down, none };
    inline bool aiming(button key) { return key >= button::aim_left && key <= button::aim_down; }
    // Read-only adapter layout proven by retail KeyDown/KeyUp and movement
    // binding cases. This is kbutton state, not a usercmd or gameplay outcome.
    struct movement_key_snapshot
    {
        std::int32_t down[2]{};
        std::int32_t downtime{}, msec{};
        std::uint8_t active{}, was_pressed{};
        std::uint8_t padding[2]{};
    };
    static_assert(sizeof(movement_key_snapshot) == 0x14);
    static_assert(offsetof(movement_key_snapshot, active) == 0x10);
    inline constexpr std::array<std::uint32_t, 4> movement_key_offsets{0, 0x14, 0x50, 0x64};
    inline bool movement_key_offset(button key, std::uint32_t& offset)
    {
        const auto index = static_cast<unsigned>(key);
        if (index >= movement_key_offsets.size()) return false;
        offset = movement_key_offsets[index]; return true;
    }
    inline constexpr std::array<const char*, 14> bindings{
        "+forward", "+back", "+moveleft", "+moveright", "+gostand", "+melee", "+activate", "+reload", "+speed_throw", "+attack",
        "+left", "+right", "+lookup", "+lookdown"};
    inline constexpr std::array<std::string_view, 15> names{
        "forward", "back", "left", "right", "jump", "melee", "use", "reload", "ads", "fire",
        "aim_left", "aim_right", "aim_up", "aim_down", "none"};
    struct key_probe { std::uintptr_t code{}, address{}; std::int32_t displacement{}; bool lea_rdi{}; };
    inline bool key_probe_for(button key, key_probe& result)
    {
        constexpr std::array<key_probe, 8> probes{{
            {0x14032DA64, 0x141FE5908, 0x1CB7E96, false}, {0x14032DA91, 0x141FE591C, 0x1CB7E7D, false},
            {0x14032DABE, 0x141FE5958, 0x1CB7E8C, false}, {0x14032DAEB, 0x141FE596C, 0x1CB7E73, false},
            {0x14032EB4E, 0x141FE58E0, 0x1CB6D84, true}, {0x14032EB85, 0x141FE58F4, 0x1CB6D61, false},
            {0x14032EBB2, 0x141FE5930, 0x1CB6D70, false}, {0x14032EBDF, 0x141FE5944, 0x1CB6D57, false}}};
        const auto index = static_cast<unsigned>(key);
        if (index < 4) { result = probes[index]; return true; }
        if (aiming(key)) { result = probes[4 + index - static_cast<unsigned>(button::aim_left)]; return true; }
        return false;
    }
    inline constexpr key_probe strafe_probe{0x14032EC0C, 0x141FE5980, 0x1CB6D66, false};
    enum class action { arm, press, release, hold, release_all, abort };
    struct request { std::uint32_t pid{}; std::string nonce; std::uint64_t sequence{}, step{}; action operation{}; button key{button::none}; std::uint64_t duration{}; };
    inline bool nonce_valid(std::string_view value)
    { return value.size() == 32 && value.find_first_not_of("0123456789abcdef") == std::string_view::npos; }
    inline bool heartbeat_valid(std::string_view nonce, std::string_view expected_nonce, std::string_view generation,
        bool same_endpoint, std::uint64_t probe, std::uint64_t acknowledged, std::uint64_t sent, std::uint64_t now)
    {
        return nonce == expected_nonce && nonce_valid(nonce) && nonce_valid(generation) && same_endpoint &&
            probe > acknowledged && probe <= sent && now >= probe && now - probe <= 300;
    }
    template<typename T> inline bool number(std::string_view value, T& result)
    {
        const auto parsed = std::from_chars(value.data(), value.data() + value.size(), result);
        return !value.empty() && parsed.ec == std::errc{} && parsed.ptr == value.data() + value.size();
    }
    inline bool parse(std::string_view wire, request& result)
    {
        if (wire.empty() || wire.size() > 256) return false;
        std::istringstream stream{std::string(wire)};
        std::array<std::string, 7> fields; std::string extra;
        for (auto& field : fields) if (!(stream >> field)) return false;
        if (stream >> extra) return false;
        request candidate;
        if (!number(fields[0], candidate.pid) || !candidate.pid || !nonce_valid(fields[1]) ||
            !number(fields[2], candidate.sequence) || !candidate.sequence ||
            !number(fields[3], candidate.step) || !candidate.step || !number(fields[6], candidate.duration)) return false;
        candidate.nonce = fields[1];
        if (fields[4] == "arm") candidate.operation = action::arm;
        else if (fields[4] == "press") candidate.operation = action::press;
        else if (fields[4] == "release") candidate.operation = action::release;
        else if (fields[4] == "hold") candidate.operation = action::hold;
        else if (fields[4] == "release_all") candidate.operation = action::release_all;
        else if (fields[4] == "abort") candidate.operation = action::abort;
        else return false;
        unsigned index{}; for (; index < names.size(); ++index) if (names[index] == fields[5]) break;
        if (index == names.size()) return false;
        candidate.key = static_cast<button>(index);
        const bool keyed = candidate.operation == action::press || candidate.operation == action::release || candidate.operation == action::hold;
        if (keyed == (candidate.key == button::none)) return false;
        if (candidate.operation == action::hold ? candidate.duration < 1 || candidate.duration > 5000 : candidate.duration != 0) return false;
        if (aiming(candidate.key) && candidate.duration > 250) return false;
        result = candidate; return true;
    }
    struct safety { bool connected{}, protected_now{}; std::string map; std::uint64_t received{}; };
    inline bool observation_valid(std::string_view nonce, std::string_view generation,
        unsigned slot, std::uint64_t probe, std::uint64_t now, bool bound, bool protected_now)
    { return slot == 0 && bound && protected_now && nonce_valid(nonce) && nonce_valid(generation) && probe && now >= probe && now - probe <= 500; }
    // Pure bounded state machine. The adapter supplies native binding dispatch,
    // trusted server protection heartbeats and a monotonic clock.
    class scenario
    {
        std::uint32_t pid_; std::string nonce_; std::uint64_t sequence_{}, step_{}, began_{}, clock_{};
        bool armed_{}; std::string map_;
        std::array<bool, bindings.size()> held_{}; std::array<std::uint64_t, bindings.size()> until_{};
    public:
        scenario(std::uint32_t pid, std::string nonce) : pid_(pid), nonce_(std::move(nonce)) {}
        bool active() const { return armed_; }
        bool pending() const { return std::any_of(held_.begin(), held_.end(), [](bool value) { return value; }); }
        std::uint64_t sequence() const { return sequence_; }
        std::uint64_t step() const { return step_; }
        std::uint64_t due(button key) const { const auto i = static_cast<unsigned>(key); return i < until_.size() ? until_[i] : 0; }
        static bool safe(const safety& s, std::uint64_t now)
        {
            const bool known_map = s.map == "cp_zmb" || s.map == "cp_rave" || s.map == "cp_disco" || s.map == "cp_town" || s.map == "cp_final";
            return s.connected && s.protected_now && known_map && s.received && now >= s.received && now - s.received <= 500;
        }
        template<typename Dispatch> void release_all(Dispatch dispatch)
        {
            for (unsigned i = 0; i < held_.size(); ++i) if (held_[i]) dispatch(static_cast<button>(i), false);
            held_.fill(false); until_.fill(0);
        }
        template<typename Dispatch> void stop(Dispatch dispatch) { release_all(dispatch); armed_ = false; }
        template<typename Dispatch> const char* tick(std::uint64_t now, const safety& s, Dispatch dispatch)
        {
            const bool reversed = now < clock_; clock_ = now;
            if (!armed_) return nullptr;
            const char* reason = reversed ? "clock_reversed" : !safe(s, now) ? "protection_lost" :
                s.map != map_ ? "map_changed" : now - began_ >= 30000 ? "deadline" : nullptr;
            if (reason) { release_all(dispatch); armed_ = false; return reason; }
            bool completed{};
            for (unsigned i = 0; i < held_.size(); ++i)
                if (held_[i] && now >= until_[i]) { dispatch(static_cast<button>(i), false); held_[i] = false; until_[i] = 0; completed = true; }
            return completed ? "step_complete" : nullptr;
        }
        template<typename Dispatch> const char* accept(const request& r, std::uint64_t now, const safety& s, Dispatch dispatch)
        { return accept(r, now, s, dispatch, [now]() { return now; }); }
        template<typename Dispatch, typename Clock> const char* accept(const request& r, std::uint64_t now, const safety& s, Dispatch dispatch, Clock clock)
        {
            if (r.pid != pid_ || r.nonce != nonce_) return "identity_rejected";
            if (r.sequence <= sequence_ || r.step <= step_) return "replay_rejected";
            if (pending() && (r.operation == action::press || r.operation == action::hold || r.operation == action::arm)) return "busy_rejected";
            sequence_ = r.sequence; step_ = r.step;
            if (r.operation == action::abort || r.operation == action::release_all)
            { release_all(dispatch); armed_ = false; return r.operation == action::abort ? "aborted" : "released"; }
            if (tick(now, s, dispatch) && !armed_) return "aborted";
            if (!safe(s, now)) return "safety_rejected";
            if (r.operation == action::arm)
            {
                if (armed_) return "already_armed";
                release_all(dispatch); armed_ = true; began_ = now; map_ = s.map; return "armed";
            }
            if (!armed_) return "not_armed";
            const auto i = static_cast<unsigned>(r.key);
            if (i >= held_.size()) return "binding_rejected";
            if (r.operation == action::hold && (r.duration < 1 || r.duration > 5000 || (aiming(r.key) && r.duration > 250))) return "duration_rejected";
            if (r.operation == action::release)
            { dispatch(r.key, false); held_[i] = false; until_[i] = 0; return "released"; }
            if (held_[i]) dispatch(r.key, false);
            // A native adapter returns the timestamp directly after the retail
            // call. Pure/legacy void adapters inject a monotonic clock instead.
            std::uint64_t actual{};
            if constexpr (std::is_void_v<std::invoke_result_t<Dispatch, button, bool>>) { dispatch(r.key, true); actual = clock(); }
            else actual = dispatch(r.key, true);
            held_[i] = true;
            const auto duration = r.operation == action::press ? 200 : r.duration;
            if (actual < now || actual < clock_)
            { stop(dispatch); return "clock_reversed"; }
            if (actual > std::numeric_limits<std::uint64_t>::max() - duration)
            { stop(dispatch); return "clock_overflow"; }
            until_[i] = actual + duration;
            // Dispatch may stall: it cannot extend stale protection or the arm
            // lifetime. Release immediately on return if either has expired.
            if (tick(actual, s, dispatch) && !armed_) return "aborted";
            return "dispatched";
        }
    };
    // Safe at namespace/static initialization: construction performs no crypto,
    // clock or engine calls. Activate only after the engine component lifecycle
    // has finished CRT initialization and only for explicit laboratory profiles.
    struct lab_session
    {
        std::string client_nonce, server_generation;
        std::unique_ptr<scenario> client;
        template<typename Generate> void activate(std::uint32_t pid, bool client_enabled, bool server_enabled, Generate generate)
        {
            if (client_enabled && !client)
            {
                const auto nonce = generate();
                auto state = std::make_unique<scenario>(pid, nonce);
                client_nonce = nonce; client = std::move(state);
            }
            if (server_enabled && server_generation.empty()) server_generation = generate();
        }
    };
}
