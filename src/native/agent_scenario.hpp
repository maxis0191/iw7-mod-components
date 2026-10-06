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

namespace iw7::agent
{
    enum class button : unsigned { forward, back, left, right, jump, melee, use, reload, ads, fire, none };
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
    inline constexpr std::array<const char*, 10> bindings{
        "+forward", "+back", "+moveleft", "+moveright", "+gostand", "+melee", "+activate", "+reload", "+speed_throw", "+attack"};
    inline constexpr std::array<std::string_view, 11> names{
        "forward", "back", "left", "right", "jump", "melee", "use", "reload", "ads", "fire", "none"};
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
        result = candidate; return true;
    }
    struct safety { bool connected{}, protected_now{}; std::string map; std::uint64_t received{}; };
    // Pure bounded state machine. The adapter supplies native binding dispatch,
    // trusted server protection heartbeats and a monotonic clock.
    class scenario
    {
        std::uint32_t pid_; std::string nonce_; std::uint64_t sequence_{}, step_{}, began_{}, clock_{};
        bool armed_{}; std::string map_;
        std::array<bool, 10> held_{}; std::array<std::uint64_t, 10> until_{};
    public:
        scenario(std::uint32_t pid, std::string nonce) : pid_(pid), nonce_(std::move(nonce)) {}
        bool active() const { return armed_; }
        bool pending() const { return std::any_of(held_.begin(), held_.end(), [](bool value) { return value; }); }
        std::uint64_t sequence() const { return sequence_; }
        std::uint64_t step() const { return step_; }
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
            if (r.operation == action::release)
            { dispatch(r.key, false); held_[i] = false; until_[i] = 0; return "released"; }
            if (held_[i]) dispatch(r.key, false);
            dispatch(r.key, true); held_[i] = true;
            until_[i] = now + (r.operation == action::press ? 200 : r.duration);
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
