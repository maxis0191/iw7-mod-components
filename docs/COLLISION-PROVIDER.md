# Original convex boxes — experimental native provider

This candidate creates the eight corners of a box in the game's native Havok
factory, then uses the retail capsule body-instantiation path with a scoped
replacement shape. It does not generate `havokWorldShapeData`, a new map, an
HKX archive, a trigger, or an analytic replacement for engine traces.

## Current evidence

The first actual zero-client probe ran on 2026-10-14 against compiled56/B78.
Private loopback UDP27116 returned real game protocol2, zero clients and
running cp_zmb; native privacy reported LAN-only and heartbeat suppression.
The original dedicated stdin pipe wrote32 bytes, and the subsequent token-bound
GSC SAFETY/trace records establish that arm reached the engine. No client started.

The provider refused `collision_createbox` before allocation with its combined
solid/linked guard, despite the fixture calling retail `solid()` immediately
beforehand. All six before/inside/after point fractions were1. No native body,
native point/actor query or destruction record was produced. The fixture's
continued DONE after an undefined return was correctly rejected by the parser.
The future fixture now stops explicitly on an undefined creation result.

Normal continuous empty UDP/quit closed the dedicated with exit0. Managed
candidate files and bank were restored; Main static files were unchanged and
its bank delta was false. The original bundled NoExit host was then explicitly
exited with failure1. Fresh process/port observations found the exact host,
parent and dedicated absent, and the runtime lease was absent. The failed
result and its closure witness remain separate immutable local evidence.

The refusal does not identify the failing field. A bounded1,550-byte read of
the retained patched snapshot confirms the retail producer's1016-byte entity
stride/compared raw word+0x1a8, contents+0x130 writes1 or0x2080 depending on a runtime
class constant, and the linker's byte+0x110 write1. Those offsets are source
evidence, not an effective-value observation from the failed process.
No class name is assigned to the constants without actual engine evidence.
The pinned packed SDK declaration instead places its `classname` member at
0x1ac; +0x110/+0x130 are inside its opaque padding. Matching entity stride does
not qualify that layout. The diagnostic records the SDK member/offset and the
producer's raw compared word separately, without renaming either as the other.

The Native14 source candidate preserves the current admission guard. It logs raw
contents/link/class IDs before refusal and reads the producer's two runtime
class-ID globals only after checking their exact RIP-relative instruction
signatures. It also verifies the link-byte producer. This read-only diagnostic
compiled successfully on 2026-10-14; it has not run in the engine. It neither accepts0x2080, drops linking,
forces contents nor bypasses the guard. A future separately pinned build/run
must observe the effective values before choosing a corrective policy.

The full Release build and existing required fixtures passed from sealed clean
source `02eab0c73d41a842e18caad13e9b6ffe6c480b89` (318 files, 2,992,655 bytes).
Of its36 native raw sources,35 match the previous B78 build; only the read-only
`collision_provider.cpp` diagnostic differs. The existing Build-Voice body
preserved available native overlays/output before its first compiler action.
EXE/PDB/manifest hashes were observed inside the same original build reservation
before release. Original build host and caller exited0; the owned job was empty
before disposal and fresh observations found the exact processes absent and
the registry empty. No dedicated/client started, no Main file was deployed and
no runtime collision or owner acceptance was claimed. B78 and failed probe A
remain separate retained evidence.

Source inspection identified the strided-vertices factory and its 56-byte
configuration constructor in the retained, already patched IW7 code snapshot.
The native capsule factory calls that same factory after generating vertices.
The code converts local corners by the wrapper's observed 1/32 scale. The
capsule body path preserves the returned shape's allocation header and uses
the normal body creation, world insertion and reference-release code.

The retained trace decoder's exact switch table maps reference system 0 to
world entity 2046. The body therefore uses world reference 0 in both server
and client worlds. The script-model number is a teardown owner, not the hit
or prediction reference. This avoids a guessed server/client entity-ref ABI;
fresh traces and movement still have to qualify the result.

Twelve pure PowerShell checks pass: profile refusal before admission, exact
source selection, removal of an unchanged disabled overlay and preservation
of an independently edited overlay. On 2026-10-13, the C++ geometry/admission
test, the required native regression suite and the complete Release image
compiled and passed in one serialized build. The original command exited 0;
its exact process tree and resource lease were subsequently absent. No fresh
engine trace, sweep, player collision, client prediction or lifecycle
acceptance has been obtained yet.

The separately composed build input is commit
`c32c1ff245e0357dfb8778afb2bbd215eda49a5c`, including the reviewed observational
client-protection API from PR7. Its 309-file, 2,853,818-byte source package
verified unchanged after building against upstream `77e6d4d`. The manifest
declares `CollisionProvider=true`, 36 native sources and a clean source
identity. The executable SHA-256 is
`2C8205B579A357EC3A96FA81958BFCD56F2AF65CD26F2E59CD6EC9BE3064455C`;
the retained matching PDB SHA-256 is
`D2CF71FDC4A98B70EAD318CBA522560D1353D7FCA1023C602DBE3DB460D1CC06`.
This qualifies compilation only. The provider and protection getter have not
been activated in a game process, and the historical native958 image remains
unchanged.

Exact-head CI for `c32c1ff` was inspected through the backend and actual jobs.
Runs `38461029590` / `38461025992`, checks `115515923187` / `115515913589`,
both have `runner_id=0`, no steps and the account payment/spending-limit
admission annotation. No CI test executed; the owner's conditional admission
exception does not turn those checks into passes or waive runtime acceptance.

The earlier proposed sphere-body adapter was rejected during source review:
it rewrites a 128-byte allocation header, which is unsuitable for a variable
size convex shape. It was never compiled or executed. The capsule adapter
avoids that overwrite. Retained unwind chains were followed; the first unwind
fragment alone is not treated as the complete function.

## Dependencies and limits

The eight corners are original geometry. Body properties and a physics material
come from the game's already loaded default `PhysicsAsset` at the qualified
binding; the provider does not load a donor map or copy a stock HKX. A fresh run
must record that template's actual name and verify the instantiated body's
contents, static/sensor behavior, traces and movement. Entry signatures are
checked before installing the hook; they are a refusal guard, not ABI proof.

The runtime flag is `-paris-collision-provider`, together with
`-paris-isolated-lab`. Without the provider flag no collision bindings, hook,
commands or GSC methods are installed. The dedicated must also be loaded,
bound to `127.0.0.1`, password protected and `sv_lanOnly=1` before creation.
Use the existing heartbeat-suppressed private test profile and complete shared
resource ownership. Main UDP27016 and an occupied owner client are preserved.

This first API permits dedicated worlds 0/1 only; the current GSC method
creates world 0. Client activation returns before bindings/hooks/commands and
client creation is also refused by the allocation policy. A ready client world
and launch flags cannot establish its current private endpoint or generation.
Independent review found that the server VM pre-shutdown callback would leave
client records containing IDs and asset pointers across disconnect/map reset.
Clearing those against a recycled world could destroy somebody else's body.
The correction refuses clients while the real pre-reset client lifecycle and
loopback/private connection are investigated. It does not clear stale pointers
or treat a server callback as client cleanup.

It does not replicate colliders automatically or prove player prediction.
Explicitly clear a model's boxes before deleting it. The dedicated's existing
pre-shutdown callback also clears owned instances. Server/client reset lifetime
and epoch validation remain required before any claim of persistent map support.

## Creator interface

Build the reviewed isolated Modules profile with `Build-Voice.ps1
-ServerModules -IsolatedLab -CollisionProvider`. Its manifest declares
`CollisionProvider: true` and includes `collision_provider.cpp` and
`collision_provider.hpp` in addition to the ordinary 34 sources (39 with the
debugger). A false or absent declaration retains the historical inventory.
The server package checker accepts the explicit 36/41-file variant. The
historical native958 image and SourceTip's strict 34-file pin are unchanged.

After the engine has loaded the private scenario, an owned script model can
request an independent box with world-coordinate minimum and maximum:

```c
floor = spawn("script_model", (0, 0, -8));
floor solid(); // Retail contents and entity linking; still no shape until below.
instance = floor collision_createbox((-256, -192, -16), (256, 192, 0));
// Keep the same entity until its boxes have been removed.
floor collision_clearboxes();
floor delete();
```

Rendering remains the asset/World product's responsibility. A `setmodel` is
optional for this collision probe and is not evidence of a collision asset.
Console commands, dispatched on the owning engine thread, are:

```text
collision_box_create <world> <script-model entity> <minX> <minY> <minZ> <maxX> <maxY> <maxZ>
collision_box_probe <world> <instance>
collision_box_clear
```

The probe logs results returned by `PhysicsQuery_LegacyTrace`, including
fraction, normal, contents, hit type/ID, startsolid and allsolid. Its point
path crosses the box top from +80 to -80. Its second query passes engine
bounds with half sizes (15,15,36) from +80 to +20. This query's actual shape
and margin must be identified before comparing it to World's AABB oracle.

## Next decisive test

The 2026-10-14 server-only route is `ops/Run-CollisionProbe.ps1`. Its default
Plan mode reads bounded manifest/source metadata and the original GSC fixture;
it does not reserve, open an EXE/PDB, enumerate processes, stage or launch.
Run requires a freshly composed native operation package plus an explicit
hash-bound prepared server-helper package. The route reuses existing resource,
bank isolation, transaction, original process-handle, UDP, fatal-diagnostic and
restoration helpers. It adds no scheduler and changes no shared server file.

The next admitted image is the separately compiled Native14 diagnostic source
`02eab0c73d41a842e18caad13e9b6ffe6c480b89`, EXE
`5931CD975C5CD2086900D599A7F79B2BF1969E64899D1E0360B6ED40225DF874`,
manifest `81105E9B5E7FF92BB160BB375B18C4E39B55D3C13FD8671F38A2A2AC8389799C`
and PDB `7BD65750C12A119953181DDF529394B92BC47E7183653056FBC523CC8F59ECCD`.
It declares `CollisionProvider=true` and 36 sources. There is no
`CollisionProbeCapability` field. The consumer pins that actual compiled tuple;
the collision guard and shared lifecycle/transport are unchanged. No further
C++ rebuild is required for the next diagnostic-only zero-client run. The old
c32/B78 executables, symbols, failed proposals and receipts remain intact.

The runtime group contains one marked retained dedicated on loopback UDP27116,
zero clients and no FF/asset build or debugger. Its generated config uses a
fresh password, LAN-only startup, empty fs_game, inactivity0 and cheats0. The
controller first binds real UDP protocol2, private/empty cp_zmb, native privacy
telemetry and the fresh fixture token to the original process. Only then does
it arm the GSC thread. The ordinary manifest Protocol1 is never used as game
protocol evidence.

The fixture measures the same retail point trace at center and near an edge,
before creation, during the original box and after explicit clear/delete. It
also requests the provider's actual native point and actor queries. Acceptance
requires a clear baseline, the original top plane at both points, observed
native allocation/queries/destruction and clear post-removal point queries.
The actor's exact shape/margin, post-removal actor query, static/sensor flags,
template usage-counter restitution, reset lifetime and player movement remain
unqualified. Point0.5 and actor44/60 are expectations, not measured results.

Review of the first runner found a real transport refusal before execution:
the shared `Send-ServerCommand.py --module-client` accepts only its three fixed
client connect/disconnect/quit strings, and refused the probe's arm command.
Its normal console route also does not establish owned stdin for the NUL-input
launcher. No failed game run is invented; those source candidates are retained.
The correction uses the existing `IW7LabProcess` launcher and original kernel
handle with a separate dedicated collision stdin role and upstream `-wincon`.
Only the exact arm command and quit are permitted, each once, on that role's
private pipe. Rig commands, client targets, reopened handles and arbitrary text
are refused. The shared sender and original eight-command rig policy are not
expanded. Runtime C# comes from the reviewed operation package; B78 C++ bytes
and the compiled56 manifest remain unchanged. Compiled policy and actual caller
dispatch to a mocked owned transport pass, including foreign PID/image/creation,
role, exited-handle and command refusal. Existing48 rig policy and5 caller lease
checks still pass. A pipe-write result is not engine consumption; only the
fixture's fresh subsequent measurements can prove execution.

Before staging, Run acquires the shared lease, verifies prepared sources and
36 raw source hashes, hashes EXE/PDB under that lease and snapshots candidate
files/profile/bank with a separate read-only Main audit. The staged image is
held open against replacement. Normal stop requires30 seconds of valid empty
UDP bound to the exact original handle/creation/image and a guarded quit.
Correlated fatal recovery preserves diagnostics and validates bank backups;
missing UDP alone never authorizes termination. Closure, vacancy and bank
file-identity isolation precede any restoration. An uncertain cleanup keeps
the original host, handle, backups and lease alive. The caller must separately
observe the original host's exit after the result returns.

Primary call evidence is the pinned upstream77e6d4d `script_extension.cpp`
implementation of `executecommand` and the IW7 builtin map's `bullettrace`
entry at0x140B4A000. Retained retail `scripts/mp/utility.gsc::getplant` uses
`bullettrace(start,end,0,undefined)` and its fraction/position/normal fields.
No retail script bytes are copied into this product. Pure transcript tests
pass, including numeric, identity, order, allocation/removal, partial-line and
terminal TAB/CRLF refusals. The corrected undefined-result fixture and this
Native14 consumer tuple have not run in a game.

Use the separately identified compiled candidate under the next coordinated
heavy workload slot. Do not reuse native958's executable or runtime evidence.
First create one elevated box in a zero-client private dedicated and inspect
real engine traces plus removal. Keep the point fraction 0.5 and the AABB
oracle 44/60 as expectations, not measured outcomes. Qualify the actual client
pre-reset lifecycle, generation binding and loopback/private endpoint before
reenabling client creation. Then mirror the box into the protected rendering
client, establish fresh engine godmode/inactivity0/sv_cheats0 and observe standing,
falling, contact and movement. Preserve any failed build/run and update this
record with the exact candidate and results.
