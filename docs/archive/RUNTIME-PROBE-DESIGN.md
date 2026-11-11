> History (dated 2026-11-08). Not current instructions. Current entry point: [docs/INDEX.md](../INDEX.md). This was a proposal and was never built; the need it describes is now largely answered by the memory watch ([MEMORY-WATCH.md](../MEMORY-WATCH.md)) and the live world editor ([WORLD-LIVE.md](../WORLD-LIVE.md)). Paths in the text are relative to the repository root as it was on that date.

# Runtime truth probe (design, not built)

Status: proposal. Nothing here is compiled, installed or qualified. It is the
highest-impact instrument found by the 2026-11-08 screenshot-use audit, and it
needs a private native build plus a protected client run, both behind the
shared resource lease. Owner of the code: this repository (private client
diagnostics); it extends the agent fixture's `capture` action.

## Problem it removes

Agents repeatedly ran in-game witnesses to answer state questions with frames:
whether an effect spawned, whether a sound played, whether a texture loaded,
which FOV and ADS state the client was really in, whether the camera moved.
Frames answered these indirectly, through timing, lighting, occlusion and FOV,
and the answers flipped between runs. Examples from retained transcripts:

- BO3 FX probes 1-9 (2026-11-06/07, about 6 hours): invisible converted
  effects, an occluding canopy, a "contradicting" run; root cause an effect
  header written wrongly, found from code once frames stopped helping.
- ADS (2026-11-06, about 1.5 hours): no zoom in any frame while the server
  reported `playerads()=1`; the harness never delivered ADS to the client.
- FOV (2026-11-07): frames labelled FOV 65 were taken at 120 because
  `setclientdvar cg_fov` was not applied; poses were judged on them.
- Sound (2026-11-08): the client never opened the lab bank because its header
  named `bo3wpn` while the client opens `mod.sabl`; audio captures and frames
  took hours to show it.
- A violet "beam" in panoramas: an endlessly looping trail element living
  after its projectile; frames could not say which effect or owner.

## Instrument

On every scenario `capture` (and on a `probe` scenario action), the client
writes one JSON line next to the frame, from the main thread, read-only:

1. Client state: frame number, client and server time, view origin and
   angles, `cg_fov` and the effective FOV, ADS fraction, current weapon and
   viewmodel animation, whether the intro/fullscreen UI is up.
2. FX census, legacy system: walk `FX_GetSystem(0)` (0x140AC0E00) from
   `firstActiveEffect` through `allEffectHandles` under
   `FX_WaitEnterReadSystemLock`. Per effect: definition name, status flags
   (looping, hidden, ref count), element counts per class, `msecBegin`, age,
   origin (`frameNow`), owner entity, bolt and `FX_EFFECT_FLAG_BOLTED_TO_ENTITY`.
   Flag effects alive past their owner and looping effects older than N s.
   Offsets come from iw7-mod `component/fx/structs.hpp` (asserted sizes).
3. FX census, IW7 particle systems (the BO3 conversions use these): the
   particle manager layout is not mapped. Count spawn requests per definition
   at the registration/spawn hook instead of walking the pool. This part needs
   reverse engineering first; do not guess offsets.
4. Asset resolution: every `DB_FindXAssetHeader` (0x140A76E00) result for
   which `DB_IsXAssetDefault` (0x140A780D0) is true, as (type, name, first
   frame). This turns "the gun renders grey" into "image X fell back to
   default".
5. Sound: alias play requests with their result (alias missing, not
   resident, voice started, voice culled) and every sound bank file open with
   its result.

The scenario runner already stores capture paths and hashes; it would store
the sidecar line beside each, and `iw7_frame_evidence.py` would carry it into
its report.

## Gates before any build

- Read-only: no writes into engine state, no new network traffic, no change
  to the standard public client; private agent build only.
- One heavy group at a time under the shared lease; never interrupt an
  occupied client or Main.
- First qualification: a stock weapon and a stock effect on the private test
  dedicated, compared with known retail behaviour, before trusting it on
  converted assets.
