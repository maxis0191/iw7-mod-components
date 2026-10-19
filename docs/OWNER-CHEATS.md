# Persistent owner-only native console access

Console `tp <name|#ID>` moves the authenticated owner to another active player;
`tphere <name|#ID>` brings that player to the owner. `cmd tp` and `cmd tphere`
also work. IDs match the public chat `.players` list (engine slot plus one).
Exact names win over unique case-insensitive fragments; colors are ignored and
ambiguous names are refused. Both players must be alive, standing and unlinked.
Movement uses the engine's GSC SetOrigin, retaining its teleport bookkeeping.
The client shorthand requires the matching OwnerCheats client build. Access is
checked again on the dedicated; global cheats and trust files stay unchanged.

Owner request, 19 October 2026: allow cheats only for the owner's client on the
public dedicated. This supersedes the earlier absence of native console access;
it does not restore the cancelled chat administration commands.

`sv_cheats` remains the ordinary replicated server dvar, normally zero. It cannot
be assigned a different authoritative value per player. The optional OwnerCheats
build instead makes the existing ten native command permission checks accept a
cryptographically authenticated client: god, demigod, notarget, noclip, ufo, give,
dropweapon, take, setviewpos and setviewang. Use the existing console forwarding
syntax, for example `cmd god`, `cmd noclip`, `cmd give ammo`. Actual command/game
effects retain their upstream implementations. Local cheat-flagged dvars become
editable only during the authenticated connection. Replicated, read-only and
write-protected dvars retain their other protections; server-wide settings do
not become individual settings. No operator lock or global cheat enable is added.

The server pins a P-256 owner public key. The owner client holds its private key
and pins the server's public key. Both prove possession using domain-separated
SHA-256/P1363 signatures and fresh client/server nonces. A nickname or claimed
GUID is never sufficient. Proofs are single-use, expire after ten seconds and
grant a short renewable connection-bound lease. Every direct-connect attempt
invalidates the previous endpoint grant before retail connection processing;
slot/pointer, endpoint, identity, active state and expiry are checked at command
time. No slot-0, IP, nickname or GUID-only privilege exists. The four-slot CP
dedicated is the only server path; SP and ordinary MP behavior remain upstream.

Generate a fresh private kit with `ops/New-OwnerCheatsKit.ps1 -OutputDirectory`
using an absolute unused directory outside tracked sources. The owner-private
and server-private files never enter Git or downloadable mod assets. Preserve
the kit as recovery material; regenerating it changes the trust relationship.
Its directory grants access only to the current Windows account and SYSTEM.
The files under `client/` and `server/` are the respective configuration trees.
The same-PC installation combines the four differently named files in the
existing `iw7-mod/owner-cheats/` directory. No existing Aurora/CB identity key is
read, replaced or copied. If a required key is absent or malformed, access is off.

Build from qualified source inputs using `Build-Voice.ps1 -ServerModules
-OwnerCheats` and `Build-StandardClient.ps1 -OwnerCheats`. The latter retains the
CB/Aurora standard profile, updater policy, NAT and friends compatibility. Both
builders remove only an exact, hash-qualified previous owner overlay. Unknown
changes are refused. Default builds exclude this component. Build manifests
record the opt-in and overlay identities. `owner_cheats_status` is a read-only
native console query; it does not authenticate, change modes or grant access.

Source/crypto tests do not establish gameplay or deployment. Qualify the native
builds on a private unlisted dedicated with positive owner and negative other-key
clients, including reconnect/slot reuse and map transition. Preserve an occupied
owner client. Public promotion requires the existing thirty-second empty guard,
backup, exact process identity, protected file/bank hashes and ordinary startup.
No global `sv_cheats 1` is required for testing or deployment.

## Qualification - 19 October 2026

The initial source run passed67/68 groups; Java was absent from that command's
PATH. The retained portable JDK21 passed the remaining resolver group. All68
groups are therefore locally qualified, with the initial failure retained.
The subsequently merged diagnostics changes pass their51 focused Python tests.
Windows CNG/overlay behavior tests and the standard CB/Aurora, normal dedicated
and isolated dedicated native builds pass. The exact engine source is unchanged
between the built candidate and final integration except for operational test
helpers and documentation. [Sanitized evidence](evidence/2026-10-19-owner-cheats.json).

The protected private native client proves owner authorization, refusal with a
different private key while retaining the same client identity, then owner
reconnection. A second run executes the real `cmd setviewang` handler: the owner
changes the three native values to23/34/45 and restores them; the other-key
client's same command leaves all three values unchanged. Every phase reports
fresh engine godmode, inactivity0 and sv_cheats0. Both runs close and restore
their candidate/profile/bank transactions. A concrete simultaneous-owner-client
requirement justified one bounded observer using retained private stock; no
game assets were copied. The first setup attempt failed before game launch
because of a transaction-helper name, then the corrected run passed.

The reproducible private procedure is `ops/Test-OwnerCheats.ps1`, from qualified
inputs with the isolated OwnerCheats build prepared under runtime/voice-package.
Supply separate CandidateRoot, ProtectedGameRoot and a fresh Output directory;
use Effects for the real positive/negative command. It never operates on Main.
Public promotion/startup and natural owner gameplay are separate evidence.

Inventory qualification uses the original owned wincon stdin pipe, with two fixed client teleport lines and five allowlisted dedicated map lines, bounded to20 writes per process and fresh native safety. CONIN keyboard injection is not a witness for children whose stdin is redirected. Windows transport tests verify actual reader consumption separately from gameplay.

The inventory stdin and delimiter candidates still produced no engine effect. They remain in commit history as failed diagnostics; the unused inventory-specific pipe API is removed. Two fixed, protected loopback-only fixture actions now enter the actual native client console parser with tphere #2 and tp #2. They retain client and server owner authentication. A transport acknowledgement alone is never gameplay proof.

The first parser-backed witness reached the authenticated handler and exposed a native adapter mistake: cp_laststand::player_in_laststand is a global function whose explicit first argument is the player, even when an entity supplies self. The corrected call passes that player; missing-state exceptions now retain a diagnostic reason. This failure is preserved separately from prior input-transport failures.

Multi-slot review also found a pre-existing pointer-level error: svs_clients is a client_t pointer stored at an engine symbol; symbol.get()[slot] indexes pointer storage rather than the client array. The corrected bounded helper indexes the dereferenced array. Tests cover all four client addresses, sparse counts, null and negative bounds; runtime qualification must include a target in slot1.
