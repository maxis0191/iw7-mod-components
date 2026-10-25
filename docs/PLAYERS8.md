# CP client slot compatibility (2026-10-25)

Owner authentication, moderation/teleport #IDs, cutscene voters and incident
counters now cover the engine's 18 existing CP client slots. No entity pool,
network codec, trust key or advertised party-size change is introduced.

Existing clients retain their four-player cinematic overlay format. Parties
larger than four receive ballot value zero (hidden overlay); the dedicated
still requires every active participant, including slots 4-17. Protection
storage and engine-bot protection cover 18 slots. The existing capture handshake
remains explicitly limited to its reviewed four-slot format; its matching loop
uses that format's bound, never the larger protection array.

Compiled Windows owner-policy/crypto tests pass, including slot 17, rejected
slot 18, #8/#18 and malformed #IDs. Compiled cutscene tests pass seven-of-eight
refusal, eighth vote, replacement/disconnect and out-of-range roster handling.
Overlay refusal and byte-exact restoration pass. These are source/unit tests;
full native build, private eight-occupant gameplay and owner acceptance remain
separate server integration gates. Public Main remains at four.
