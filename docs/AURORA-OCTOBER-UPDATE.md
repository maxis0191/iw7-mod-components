# Aurora upstream integration - 2026-10-17

## Source identity and compatibility

The retained ServerModules base is the owner fork integration commit
`993737428781c4357fe21ecd375300e39a29a654`. Its parents are the retained
`77e6d4d24e918ee363b3feee3735c3b889dff7d7` and official Aurora develop
`37abcb260408ce7cdef0dde831bbfcad594510e3` (official merge on 2026-10-11).
The generic-only merge is retained on the owner's public fork integration branch;
private Paris components remain in this private product and its source dependencies.
No private source or runtime data was published to the Aurora project.

The 18 October official default-branch refresh still resolves to that same
`37abcb260408ce7cdef0dde831bbfcad594510e3`; there are no newer default-branch
commits to integrate. Unmerged feature branches are outside this update.
The profile now pins successor `cfca45b11ee14641945b9a264a95638387f48a4a` of
the retained integration. It applies the same five-byte loading-new-map jump
correction as the standard CB client. The Paris executable is also used as the
VC v2 client, so its client transition path needs this correction even though
no corresponding dedicated-server crash has been demonstrated.

The build checks the loading hook after its owned client download-cache overlay
and records the source contract in the receipt. The new native pin has its own
exact normalized source hash in that overlay's allowlist; old pin/hash pairs and
frozen experiment/checkpoint pins remain unchanged. Native build, private runtime
qualification, guarded promotion and owner transition gameplay remain pending
for this successor. Earlier production evidence below belongs to the old build.

All nineteen official commits after the previous common ancestor were reviewed.
The sixteen-file integration includes shader preload cache persistence, usermap
arena/UI/Lua/fastfile support, language-zone/image-pak lookup, invalid Havok input
handling, hero loot unlocks, renderer list/umbra fixes and clean CI shader outputs.
The existing DirectX renderer remains in use. The seven retained owner-fork
commits include the zombies fix, last-seen null/signature guards and D3D11 capture.
No speculative network, timing, rate, queue or allocator tuning was introduced.
Historical Rhino/enemy and standalone legacy build pins remain unchanged.

`b5f60120b7f2883a263de717195e7149eebb38d4` redirects both engine cache reads
and writes to `fs_basepath/iw7-mod/players2/upshd.dat` and creates the directory.
This differs from the older directx.cpp upshd.d12 rename. Dedicated render shader
preload remains disabled; no ping or FPS improvement is inferred from source.

The voice relay wire protocol stays version 2; the separately retained legacy PV
helper protocol remains version 1. Build receipts now name both explicitly and
inventory actual compiled native source hashes. The original deployed manifest
was stale and must not be used to identify the previous running binary.

## Validation and promotion

The standard desktop shortcut targets `iw7-mod.exe`; the VC v2 shortcut and Main
dedicated both target `iw7-paris-voice.exe` in the existing base game installation.
No occupied client may be stopped. Aurora's successful Build run 38173874516
at exact head 37abcb2604 supplies a reference client and data artifact with
matching symbols, not a replacement for the owner's habitual CB lineage.
The prior standard binary's size 5402624 and SHA1 A2201FAA028338B99566BE3555767188B2FD25DD
match CBServers/updater files.json exactly. Its source commit is not established
by that distribution match. Preserve NAT/friends/Discord/launcher behavior through
a separate CB-compatible merged source profile, not a plain Aurora replacement.
The CB updater URL remains intact; the existing -noupdate mechanism must guard
the locally merged executable against replacement by older remote code/data.
Manage the reviewed official data delta manually at the same recorded pin.

Local download-cache ownership/writer/receipt regression passes with both exact
native pins. The scheduler source is identical at both pins and retains the same
reviewed clean/profiler/watch hashes. Native voice/parser/capture/protection tests
and private dedicated qualification are recorded with the installation evidence.

The map-transition successor `cfca45b11ee14641945b9a264a95638387f48a4a`
retains scheduler Git blob `d235aeee97891254b1c38b7841e01700e130220d` from
`77e6d4d`/`9937374`. Its first normal server build stopped before final native
compilation because the checkpoint helper treated that successor as an unknown
pin and refused the existing owned profiler overlay. The helper now recognizes
only its disabled BeforeDebugger/AfterDebugger transitions, using the unchanged
full profiler/watch hashes; `-Enabled` still refuses this successor. The Source
regression invokes the real Apply entry against temporary Source files, reproduces
the earlier refusal, and checks known transitions, mutations and unknown pins.
This correction does not qualify another native build, debugger/watch activation,
game transition or deployment. The failed package remains immutable.

GitHub Source checks on the reviewed head did not execute: the primary check
annotation reports the existing account payment/spending-limit refusal; jobs have
runner_id 0 and no steps. This is not passing CI. The current AGENTS.md conditional
exception permits this before-runner quota case after local checks and review.
Any executed failure still blocks promotion and must be fixed.

The local recovery kit under IW7-Runtime/aurora-update-20261017 contains old EXEs,
configs, scripts, bank, profile/UI backups, matching source/build receipts and the
four original native incident segments. Keep the independent incident recorder
running. Promotion requires valid zero-client getinfo replies over thirty seconds,
then exact PID/image/creation verification. Restore the backed-up EXE and manifest
for rollback after the same zero-client guard; preserve current bank balances.
Do not copy the old bank over newer transactions during a later rollback.

Source/build/private-startup evidence does not establish owner gameplay, shader
cache persistence during normal play, FPS, WAN quality or human bidirectional voice.

## Qualified normal Paris profile

Production package SHA256 is
`5B83D0A5DBD1D16A9B8E01ABC552EFB7FC3544C17B17358037C7A082AEEA1645`,
built from engine product 84ee0bd with IsolatedLab=false and Debugger=false.
The manifest records 366 source hashes and relay protocol 2. Both dedicated
startup in the private qualification and actual ordinary client frontend startup
passed; the client log confirms opt-in generic Zombies v2 installed, followed by
quit of the owned test process. No player, NAT/WAN or microphone acceptance is
implied. All 66 product source regressions passed with portable, digest-verified
Temurin 21. The first source check attempt lacked Java and is retained as failed;
the subsequent complete check passed.
