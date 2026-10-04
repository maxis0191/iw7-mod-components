#include "../../src/native/voice_state.hpp"
#include <iostream>
#include <stdexcept>

namespace v = voice::state;
void require(bool value, const char* reason)
{
    if (!value)
        throw std::runtime_error(reason);
}

int main()
{
    try
    {
        const v::session_id server{1, 2}, recipient{3, 4}, first{5, 6}, second{7, 8};
        v::listener listener;
        std::uint32_t changed{};
        v::roster snapshot;
        snapshot.server = server;
        snapshot.listener = recipient;
        snapshot.revision = 1;
        snapshot.speakers[0] = {100, first, true};
        require(!listener.accept_audio(server, recipient, 0, first, 1),
                "audio before authorized session");
        require(listener.apply_roster(snapshot, changed) == v::control_result::wrong_session,
                "control created session");
        require(listener.begin_session(server, recipient), "valid session refused");
        require(!listener.accept_audio(server, recipient, 0, first, 1), "audio before roster");
        require(listener.apply_roster(snapshot, changed) == v::control_result::applied &&
                    changed == 1,
                "initial roster");
        require(listener.accept_audio(server, recipient, 0, first, 1000), "initial stream");
        require(!listener.accept_audio(server, recipient, 0, first, 1000),
                "duplicate stream frame");

        // A reconnects while B's listener session survives. Only A's generation
        // changes: its reset sequence is valid, but delayed old audio is not.
        auto reconnect = snapshot;
        reconnect.revision = 2;
        reconnect.speakers[0].generation = second;
        require(listener.apply_roster(reconnect, changed) == v::control_result::applied &&
                    changed == 1,
                "reconnect roster");
        require(listener.accept_audio(server, recipient, 0, second, 1),
                "reconnected speaker was silenced");
        require(!listener.accept_audio(server, recipient, 0, first, 1001),
                "delayed old speaker accepted");
        require(listener.apply_roster(snapshot, changed) == v::control_result::stale_revision &&
                    changed == 0,
                "stale roster rollback");
        require(listener.accept_audio(server, recipient, 0, second, 2),
                "stale control damaged stream");
        require(listener.apply_roster(reconnect, changed) == v::control_result::repeated &&
                    changed == 0,
                "repeated control");
        require(!listener.accept_audio(server, recipient, 0, second, 2),
                "repeated control reset replay state");
        auto conflict = reconnect;
        conflict.speakers[0].generation = first;
        require(listener.apply_roster(conflict, changed) == v::control_result::conflicting_revision,
                "conflicting revision accepted");

        auto invalid = reconnect;
        invalid.revision = 3;
        invalid.speakers[1] = invalid.speakers[0];
        require(listener.apply_roster(invalid, changed) == v::control_result::invalid_roster &&
                    changed == 0,
                "duplicate user roster");
        invalid.speakers[1] = {200, {}, true};
        require(listener.apply_roster(invalid, changed) == v::control_result::invalid_roster,
                "zero speaker generation");
        invalid.speakers[1] = {0, second, true};
        require(listener.apply_roster(invalid, changed) == v::control_result::invalid_roster,
                "zero speaker identity");
        invalid.speakers[1] = {200, second, false};
        require(listener.apply_roster(invalid, changed) == v::control_result::invalid_roster,
                "absent speaker retained state");
        require(listener.accept_audio(server, recipient, 0, second, 3),
                "invalid roster mutated valid state");
        require(!listener.accept_audio({9, 9}, recipient, 0, second, 4), "wrong server session");
        require(!listener.accept_audio(server, {9, 9}, 0, second, 4), "wrong listener session");
        require(!listener.accept_audio(server, recipient, v::max_speakers, second, 4),
                "out-of-range speaker");
        require(!listener.accept_audio(server, recipient, 1, second, 4), "absent speaker");
        require(listener.accept_audio(server, recipient, 0, second, 4),
                "rejected input consumed sequence");

        auto disconnect = reconnect;
        disconnect.revision = 3;
        disconnect.speakers[0] = {};
        require(listener.apply_roster(disconnect, changed) == v::control_result::applied &&
                    changed == 1,
                "disconnect roster");
        require(!listener.accept_audio(server, recipient, 0, second, 5),
                "disconnected speaker audio");
        auto reused = disconnect;
        reused.revision = 4;
        reused.speakers[0] = {300, first, true};
        require(listener.apply_roster(reused, changed) == v::control_result::applied,
                "slot reuse roster");
        require(!listener.accept_audio(server, recipient, 0, second, 5),
                "prior slot occupant accepted");
        require(listener.accept_audio(server, recipient, 0, first, 1),
                "new slot occupant silenced");

        // A listener reconnect/map change cannot accept old controls or audio.
        const v::session_id next_server{11, 12}, next_recipient{13, 14};
        require(listener.begin_session(next_server, next_recipient), "new map/session");
        require(listener.apply_roster(reused, changed) == v::control_result::wrong_session,
                "old session control");
        require(!listener.accept_audio(server, recipient, 0, first, 2), "old listener audio");
        reused.server = next_server;
        reused.listener = next_recipient;
        reused.revision = 1;
        require(listener.apply_roster(reused, changed) == v::control_result::applied,
                "new session roster");
        require(listener.accept_audio(next_server, next_recipient, 0, first, 1),
                "new session audio");
        listener.reset();
        require(!listener.accept_audio(next_server, next_recipient, 0, first, 2),
                "audio after reset");
        require(!listener.begin_session({}, next_recipient), "zero server session");
        require(!listener.begin_session(next_server, {}), "zero listener session");

        v::sequence_window wrap;
        require(wrap.accept(0xFFFFFFFEu) && wrap.accept(0xFFFFFFFFu) && wrap.accept(0) &&
                    wrap.accept(1),
                "serial wrap");
        require(!wrap.accept(0) && !wrap.accept(1) && !wrap.accept(0x80000001u),
                "backward/duplicate/ambiguous serial");
        std::cout << "PASS: speaker reconnect, delayed old frames/control, slot reuse, "
                     "listener/map reset, roster validation and serial wrap.\n";
        return 0;
    }
    catch (const std::exception& e)
    {
        std::cerr << "FAIL: " << e.what() << '\n';
        return 1;
    }
}
