# Persistent owner-only native console access

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
