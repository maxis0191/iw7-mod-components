# Aurora upstream integration - 2026-10-17

## Source identity and compatibility

The ServerModules profile now builds the owner fork integration commit
`993737428781c4357fe21ecd375300e39a29a654`. Its parents are the retained
`77e6d4d24e918ee363b3feee3735c3b889dff7d7` and official Aurora develop
`37abcb260408ce7cdef0dde831bbfcad594510e3` (official merge on 2026-10-11).
The generic-only merge is retained on the owner's public fork integration branch;
private Paris components remain in this private product and its source dependencies.
No private source or runtime data was published to the Aurora project.

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
No occupied client may be stopped. Official standard-client input comes from
Aurora's successful Build run 38173874516 at exact official head 37abcb2604,
Release binaries and Release data artifacts, with matching official symbols.

Local download-cache ownership/writer/receipt regression passes with both exact
native pins. The scheduler source is identical at both pins and retains the same
reviewed clean/profiler/watch hashes. Native voice/parser/capture/protection tests
and private dedicated qualification are recorded with the installation evidence.

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
