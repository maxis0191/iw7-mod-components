# Automatic standard / Paris48 client profiles

Owner GO, 20 October 2026: joining a compatible server must not require players
to extract or install feature packages. The required real-engine qualification
starts with an empty feature cache, follows a normal connection to a private
64-v2 dedicated, and returns to a private standard-layout server automatically.
Main27016 and an occupied owner client remain protected.

## Design and initial-distribution boundary

The managed community client contains both reviewed native layouts. It starts
with the ordinary layout. Only a nonce-checked response from the selected server,
with gamename IW7, a supported playmode and the known 64-v2 contract, can request
a restart into the expanded layout. A standard server requests the reverse
restart. The existing mod/usermap downloader continues to handle content files;
the capacity change needs no extra retail assets or downloaded native plugin.

The same executable is used after each transition. No server-supplied executable,
DLL, command line, script or arbitrary package URL is executed. Original argv is
parsed and quoted using Windows rules; previous profile and reconnect arguments
are removed. A child checks the original parent's PID/creation identity and waits
for its exit before loading the game. It never terminates that parent or an owner
process. Unknown wire contracts, unsupported modes, changed executable bytes and
a changing server contract during reconnect fail rather than loop.

`IW7-Paris.exe` is a proposed single-file onboarding program, containing the
managed native client and its hash. It detects an existing game through its
location, Steam install/library records or user shortcuts, verifies/extracts only
the managed executable, and launches it with the existing retail installation
as working directory. It does not replace iw7-mod.exe or iw7_ship.exe, install a
driver, require elevation, download the game or copy a retail installation.
An undetected nonstandard installation can be selected with a folder picker.

An unchanged Aurora/CB executable does not acquire this functionality merely by
connecting to a server. The first client distribution remains necessary. If the
community distributor integrates it, its ordinary updater can supply that first
version. This repository cannot change a third party's release channel. Without
that integration, the player executes the one-file onboarding program once;
manual feature archive extraction is eliminated, not the first trust/execution
step. Do not describe an unchanged-client join as solved by the new client.

## Removable state and progress

Managed client: `iw7-mod/server-profiles/client/<SHA256>/iw7-paris-auto.exe`.
Expanded engine settings/shader cache: `iw7-mod/server-profiles/capacity64-v2/`.
Only the three existing configuration/key files are copied once, without an
overwrite, to retain the player's controls and graphics settings. Ordinary user
identity, stats and unlock services keep their usual paths; this is not a second
progress account. Normal gameplay can update those shared services as usual.

The capacity profile is inactive after an automatic standard restart. While all
managed clients are closed, the server-profiles folder is removable; existing
ordinary executables and normal launchers remain available. Existing content in
mods/usermaps follows the community downloader's separate folder convention.

The bounded local events journal contains process handoff identities and wire
states, without endpoint/password/player identity. It is diagnostic, not an
authorization channel. Qualification may use a private-loopback-only return
target to exercise a real 24 ->64-v2 ->24 process sequence. It grants no cheat,
native console or public-server test access.

## Current evidence and execution status

Source work is on codex/automatic-capacity-profile. The automatic overlay's
preflight, foreign-edit refusal, interrupted-application recovery, byte-exact
restoration, hook ordering and engine-settings/shader-path checks pass. PowerShell
parse checks pass. These do not qualify C++ compilation or real joining.

The first native policy compile attempt was refused by the shared scheduler:
another standard-client build owns the account-wide reservation. Its scope is
native-main-engine-thread-cpu-source, owner PID41596, lease9dc1951a09a0426c8ef7bfbb47b25a11.
The lease remains intact. No compiler/game was launched by this task and Main
was not changed. Complete the new policy compilation, full managed client build,
one-file bootstrap build, fresh-cache guarded real-engine round trip, uninstall/
normal-launch preservation and exact-head PR gates before deployment or a PASS.
