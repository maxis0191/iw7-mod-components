# Automatic standard / Paris48 client profiles

Owner clarification,20 October2026: first investigate unchanged community
clients through their existing download/content interfaces. The
[native-first audit](EXISTING-CLIENT-CAPACITY.md) records the inspected paths,
source pins, protocol observation and unexecuted real-engine checks. This
automatic-client implementation remains the fallback; initial execution of its
onboarding program does not meet an unchanged-official-client requirement.

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

The onboarding also prepares the community mod's data when absent, so a fresh
player does not depend on somebody else's warm global cdata cache. The reviewed
list has 47 publisher files/371063469 bytes, including the bundled community MP
map, and excludes dedicated-only sound metadata and executables/DLLs. It pins
CBServers/updater 0a8903a70adbd30824a1d7b3dbaccd72f1bcff51 and the two official
Usermaps files at Aurora 37abcb260408ce7cdef0dde831bbfcad594510e3. The upstream
list itself is SHA256-pinned; each data file retains its publisher SHA1/length.
Existing ordinary data is reused only after verification, otherwise the fixed
commit URL is downloaded with progress/cancel and up to three attempts. A
verified temporary is renamed into place; altered managed files are quarantined
inside the same folder. Ordinary updater data is never overwritten.

The dataset uses the first 32 hexadecimal characters of its full manifest SHA256
as a directory component, with the full identity recorded separately, to keep
normal Steam paths within the engine/Framework path limits. Managed clients
inherit that identity through their process environment only. No machine-wide
environment or IFEO registry setting is installed. The normal upstream updater
is skipped before its old-binary deletion, and the upstream HKLM loader-thread
write is skipped for this managed distribution. WMI checks preserve any running
non-dedicated IW7 game before preparation and again before client launch.

An unchanged Aurora/CB executable does not acquire this functionality merely by
connecting to a server. The first client distribution remains necessary. If the
community distributor integrates it, its ordinary updater can supply that first
version. This repository cannot change a third party's release channel. Without
that integration, the player executes the one-file onboarding program once;
manual feature archive extraction is eliminated, not the first trust/execution
step. Do not describe an unchanged-client join as solved by the new client.

## Removable state and progress

Managed client: `iw7-mod/server-profiles/client/<SHA256>/iw7-paris-auto.exe`.
Community data: `iw7-mod/server-profiles/community-data/<manifest-prefix>/cdata/`.
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
The private one-file qualification disables ordinary-cache reuse, requires 47
actual verified downloads, observes protected playable states in both layouts,
and checks three successive real client process identities. Its final private
standard receiver quits after observation; the harness preserves failures and
can recover its exact owned probe after an unresponsive orderly quit. It does
not terminate an owner client. Managed restoration and the final strict Main
bank/static audit are separate: observed bank drift remains false/unattributed,
and current bank bytes are never restored to a historical baseline.

## Current evidence and execution status

Source work is on codex/automatic-capacity-profile. The automatic overlay's
preflight, foreign-edit refusal, interrupted-application recovery, byte-exact
restoration, hook ordering and engine-settings/shader-path checks pass. PowerShell
parse checks pass. These do not qualify C++ compilation or real joining.
Actual pinned a99 source overlays compose and restore byte-exactly, including
the isolated data-root and registry/updater guards. The closed 47-file metadata
contract passes. The native-first follow-up retrieved all47 publisher bodies
from an empty cache in33.453seconds, with exact lengths/SHA1 and no retry.
The actual C# bootstrap source then compiled in a light managed data-only test:
its own PrepareData downloaded47 files, downloaded0 on a warm rerun, and repaired
exactly1 deliberately altered file while preserving the bad copy in quarantine.
No IW7 client or onboarding Main entrypoint was executed by those tests.
The first managed compilation exposed Framework csc's mixed-slash source-path
failure CS1504; a minimal reproduction failed with mixed paths and passed with
normalized paths. The package compiler now uses normalized inputs and a response
file. The full native client and one-file delivery build are still unqualified.
See the [structured evidence](evidence/2026-10-20-existing-client-capacity.json).

The first native policy compile attempt was refused by the shared scheduler:
another standard-client build owns the account-wide reservation. Its scope is
native-main-engine-thread-cpu-source, owner PID41596, lease9dc1951a09a0426c8ef7bfbb47b25a11.
The lease remains intact. No compiler/game was launched by this task and Main
was not changed. Complete the new policy compilation, full managed client build,
one-file bootstrap build, fresh-cache guarded real-engine round trip, uninstall/
normal-launch preservation and exact-head PR gates before deployment or a PASS.


## Pending build and private qualification

Run only from a fresh, verified committed product source workspace. Use a new
small native source checkout for the automatic client: the previous capacity
standard checkout also retains other feature overlays and must be preserved.
The retail base client/assets are reused; this is not a client/game clone.

1. Run tests/ops/auto_capacity_test.ps1 -Compile under its normal shared admission.
2. Run ops/Build-StandardClient.ps1 -Capacity64 -AutomaticProfiles with a fresh
   NativeRoot at the pinned a99 revision; keep BuildJobs1.
3. Run ops/Package-AutoClient.ps1 into a fresh output, then verify detection through
   the resulting one-file program before its engine qualification.
4. Run ops/auto-capacity/Qualify.ps1 with the existing stopped private-test-server,
   the real base game root, the qualified private64-v2 server package and the
   matching client/delivery packages. Its cold47-file download is explicit and
   the result must retain all cleanup/audit limits.
5. Finish exact-head review/CI/private merge and guarded client installation only
   after genuine build/runtime evidence. Main needs no experimental restart.

PR98 is private/Draft. The initial0c27e8b head's primary CI annotation confirms an
account billing/spending-limit refusal, with runner_id0 and steps[]; it is not a
hosted test PASS. A request to the owner to authorize messaging the separate
orchestrator for normal closure/controlled abandonment of its retained blocked
build is pending. No message was sent and its original lease was not altered.
