#pragma once
#include <array>
#include <cstdint>

// Pure receive state for the future generic voice component. The adapter must
// authorize a control snapshot against the current game connection before
// passing it here. An audio packet can never create or change a speaker.
namespace voice::state
{
    constexpr unsigned max_speakers = 18;

    struct session_id
    {
        std::uint64_t low{}, high{};
        bool empty() const
        {
            return !low && !high;
        }
        friend bool operator==(session_id a, session_id b)
        {
            return a.low == b.low && a.high == b.high;
        }
        friend bool operator!=(session_id a, session_id b)
        {
            return !(a == b);
        }
    };

    struct speaker
    {
        std::uint64_t user{};
        session_id generation{};
        bool present{};
        friend bool operator==(const speaker& a, const speaker& b)
        {
            return a.user == b.user && a.generation == b.generation && a.present == b.present;
        }
        friend bool operator!=(const speaker& a, const speaker& b)
        {
            return !(a == b);
        }
    };

    struct roster
    {
        session_id server{}, listener{};
        std::uint64_t revision{};
        std::array<speaker, max_speakers> speakers{};
    };

    class sequence_window
    {
    public:
        bool accept(std::uint32_t sequence)
        {
            // Serial arithmetic: accept forward movement, including wraparound;
            // duplicate/backward/ambiguous half-range values cannot rewind audio.
            const std::uint32_t distance = sequence - last_;
            if (initialized_ && (!distance || distance >= 0x80000000u))
                return false;
            last_ = sequence;
            initialized_ = true;
            return true;
        }

    private:
        std::uint32_t last_{};
        bool initialized_{};
    };

    enum class control_result
    {
        applied,
        repeated,
        wrong_session,
        invalid_roster,
        stale_revision,
        conflicting_revision
    };

    class listener
    {
    public:
        void reset()
        {
            *this = {};
        }
        bool begin_session(session_id server, session_id recipient)
        {
            reset();
            if (server.empty() || recipient.empty())
                return false;
            roster_.server = server;
            roster_.listener = recipient;
            return true;
        }

        control_result apply_roster(const roster& snapshot, std::uint32_t& changed_slots)
        {
            changed_slots = 0;
            if (roster_.server.empty() || snapshot.server != roster_.server ||
                snapshot.listener != roster_.listener)
                return control_result::wrong_session;
            if (!valid(snapshot))
                return control_result::invalid_roster;
            if (snapshot.revision < roster_.revision)
                return control_result::stale_revision;
            if (snapshot.revision == roster_.revision)
                return snapshot.speakers == roster_.speakers ? control_result::repeated
                                                             : control_result::conflicting_revision;
            // Validate the whole snapshot before changing any sequence state.
            for (unsigned slot = 0; slot < max_speakers; ++slot)
                if (snapshot.speakers[slot] != roster_.speakers[slot])
                {
                    sequences_[slot] = {};
                    changed_slots |= 1u << slot;
                }
            roster_ = snapshot;
            return control_result::applied;
        }

        bool accept_audio(session_id server, session_id recipient, unsigned slot,
                          session_id generation, std::uint32_t sequence)
        {
            if (!roster_.revision || server != roster_.server || recipient != roster_.listener ||
                slot >= max_speakers)
                return false;
            const auto& member = roster_.speakers[slot];
            return member.present && generation == member.generation &&
                   sequences_[slot].accept(sequence);
        }

        const roster& current_roster() const
        {
            return roster_;
        }

    private:
        static bool valid(const roster& value)
        {
            if (!value.revision || value.server.empty() || value.listener.empty())
                return false;
            for (unsigned slot = 0; slot < max_speakers; ++slot)
            {
                const auto& member = value.speakers[slot];
                if (!member.present)
                {
                    if (member.user || !member.generation.empty())
                        return false;
                    continue;
                }
                if (!member.user || member.generation.empty())
                    return false;
                for (unsigned other = 0; other < slot; ++other)
                    if (value.speakers[other].present &&
                        (value.speakers[other].user == member.user ||
                         value.speakers[other].generation == member.generation))
                        return false;
            }
            return true;
        }
        roster roster_{};
        std::array<sequence_window, max_speakers> sequences_{};
    };
}
