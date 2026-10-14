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
The corrected fixture stops explicitly on an undefined creation result.

Normal continuous empty UDP/quit closed the dedicated with exit0. Managed
candidate files and bank were restored; Main static files were unchanged and
its bank delta was false. The original bundled NoExit host was then explicitly
exited with failure1. Fresh process/port observations found the exact host,
parent and dedicated absent, and the runtime lease was absent. The failed
result and its closure witness remain separate immutable local evidence.

The first refusal did not identify the failing field. A bounded1,550-byte read of
the retained patched snapshot confirms the retail producer's1016-byte entity
stride/compared raw word+0x1a8, contents+0x130 writes1 or0x2080 depending on a runtime
class constant, and the linker's byte+0x110 write1. Those offsets are source
evidence, not an effective-value observation from the failed process.
No class name is assigned to the constants without actual engine evidence.
The pinned packed SDK declaration instead places its `classname` member at
0x1ac; +0x110/+0x130 are inside its opaque padding. Matching entity stride does
not qualify that layout. The diagnostic records the SDK member/offset and the
producer's raw compared word separately, without renaming either as the other.

The Native14 source candidate retained the pre-correction admission guard. It logs raw
contents/link/class IDs before refusal and reads the producer's two runtime
class-ID globals only after checking their exact RIP-relative instruction
signatures. It also verifies the link-byte producer. This read-only diagnostic
compiled successfully and ran in the separate zero-client probe B on
2026-10-14. Its guard remained unchanged for that investigation.

Probe B used compiled source `02eab0c`/EXE `5931CD975C5CD2086900D599A7F79B2BF1969E64899D1E0360B6ED40225DF874`
and the consumer merged at `ff0f8ede60445dfb87441fae132f0b455c49ccb2`.
Original private loopback UDP27116 established actual protocol2, clients0 and
cp_zmb before the32-byte arm; the subsequent fresh GSC SAFETY/trace/FAIL records
establish engine execution. Actual admission values were:

| Field | Observed value in B |
| --- | --- |
| SDK classname / ID / offset | script_model /172 /0x1ac |
| Producer raw word+0x1a8 |172 |
| Producer mask0x2080 runtime class ID |172 |
| Producer no-change runtime class ID |174 |
| Raw contents+0x130 |0x00002080 |
| Raw linked byte+0x110 |1 |

Those172/174 IDs are observations from this VM, not stable constants. The raw
word and SDK member remain distinct fields despite equal observed values.
For this actual entity, linking passed and the producer's mask0x2080 case
matched, but the provider demanded bit1 absent from0x2080. This explains the
refusal before allocation. The corrected fixture emitted create_refused FAIL
with no DONE; only the two clear before traces ran. No body creation, native
point/actor query or destruction was observed. The strict probe result stayed
false and cannot qualify collision or player movement.

B ended with a continuous empty UDP30-second window and owned quit: original
dedicated exit0/clean, candidate files and bank restored, Main static audit
unchanged and Main bank delta false. The original NoExit host then exited1,
preserving strict test failure. Fresh exact host/parent/dedicated and port
observations were absent and the registry held0 leases. The raw result, logs
and separate original-host closure witness remain intact; A was not rewritten.

The Native16 source correction preserves linked bit1 admission and adds only the
exact observed retail script_model case: linked byte1, contents exactly0x2080,
producer raw class matching both the SDK script_model ID and the current
nonzero mask0x2080 global, with a
separate nonzero no-change global. Dedicated/static script_model classification,
producer signatures/readability, ready world, loopback/password/LAN-only and
all allocation/teardown checks stay in force. For this new exception, other even/nonzero/partial masks,
foreign/no-change class IDs and missing/ambiguous globals are rejected. No
numeric172/174 VM ID is compiled into the predicate. The owner contents are
not overwritten. The generated body's existing contents1 and mask1 native
queries remain separate; admitting an owner does not prove body collision.
Native regression cases cover that exact B input and refusal boundaries, with
changed VM IDs and preservation of the old bit1 behavior. Primary and
independent reviews approved exact source head `b0e86bb`; PR16 merged at
`8f1ac6d2443feb4432bfc2f9f6915d0ba50ea0c6`. Its new C++ predicate and native
regressions compiled and passed in the full Release build. Its first engine
run C crashed as recorded below; no successful body/query/teardown or gameplay
follows from the source/build checks.

The actual Native16 build used clean sealed source `8f1ac6d` (318 files,
2,999,759 bytes), with36 raw native sources and only the provider CPP/HPP
differing from Native14. Existing required fixtures and the new admission
regressions passed. The original admitted firstBody preserved37 available
native overlay/output files. Actual EXE/PDB/manifest hashes were captured
inside the same original build reservation before release. Build host and
original PTY exited0, owned job active count was0 before disposal, and a fresh
check found all75 observed tree identities absent and registry0. No engine
process/client or Main deployment occurred. Native14/B/A remain intact.

The first Native16 engine probe C subsequently ran with compiled source8f1/
EXE `A47E4F6464D208D612DE85E40D77E5FD106D3CB092B9029E9C4B83844C6FB7CD`
and consumer `ccfb2f2a3111cc7c5d4d344fd43fd849afd269a1`. Private loopback
protocol2/clients0/cp_zmb,32-byte arm and token-bound SAFETY/before traces were
observed. The raw owner diagnostic matched B's script_model/SDK172/raw172/
global2080=172/no-change174, contents0x2080 and linked1. A native fatal error
followed before any successful created/query/destroy or inside/after receipt.
The absence of those success receipts does not prove that no earlier native
allocation occurred.

The fresh dump/dialog correlated with the original executable, PID and creation
identity. Its already-produced JSON recorded C0000005 at0x14057BA84, read
target0x60. The retained57B9C0 code has `mov rcx,[rsi+0x60]` at that exact site;
RSI receives the preceding0x140578C00 lookup return. This locates the immediate
null-base candidate, not a proven argument/asset-registration root cause. The
parsed JSON exposes a thread count, not registers, and explicitly requires
matching-symbol unwinding for a real stack. No further opaque dump/PE/PDB/CDB
analysis follows from this source-only evidence.

Existing correlated-fatal recovery preserved the dump/parser result, checked
bank backups, and terminated the exact dedicated with3758096385/0xE0000001.
Strict probe result was false; its surfaced Receive timeout remains distinct
from the native fatal context. Candidate files/bank restored, Main static audit
unchanged/bank delta false, then the original NoExit host exited1. Fresh exact
host/parent/dedicated and test port were absent and registry0. Raw A/B/C,
original result, fatal recovery and separate closure witness remain intact.
No functional body/query/sweep/removal, player or owner acceptance is claimed.

Primary source review of the retained431-byte54FBD0 wrapper confirms the15
argument slots currently declared: first ID, second world, third pointer,
followed by the preserved stack scalars/origin/quaternion/flags. It does not
prove that the third pointer is a PhysicsAsset object. The retained596-byte
retail volume caller at56C650 loads the same141BA4500 slot, calls54EC30 with
that value, and passes the returned pointer as arg3. The current provider
instead passes the slot value directly. That is a concrete provenance
difference; the54EC30 transform's semantics and578C00 lookup implementation
are not present in the already-extracted JSON. A pointer/type/library fix
requires that missing qualification, not an invented argument shift or blind
asset replacement. The owner2080 admission is orthogonal to this failure.

Subsequent separately admitted analyses D/E used the existing bounded reader.
D selected54EC30/578C00 only,195 bytes:54EC30 is a5-byte tail jump to577A10;
578C00 is a190-byte lookup keyed by the exact input pointer, returning its
stored value or0. A found entry can also contain value0. E followed only the
justified577A10 body,241 bytes. It compares the input's bytes with each occupied
object's name pointer at+0 through NUL, case-sensitively, and returns that
matching object pointer or0. D/E RIP table references match0x144BE1488; E's
returned key is the pointer D subsequently looks up. No table creation/write
is visible in E; its surrounding indirect calls remain unqualified.

This qualifies the missing name-to-object resolution in the provider's arg3
route. Name+0 and retail returned-object usage+0x40 agree with the pinned
PhysicsAsset SDK layout, while full runtime body availability is not proven.
The correction treats141BA4500 as a name-pointer slot, refuses null/empty/
unreadable or unterminated laboratory names before the native comparator,
resolves through54EC30, validates the returned asset, and preflights578C00 on
that resolved object. Null/unreadable runtime context is refused before shape
or instance creation. The bounded name limit is a local validation contract,
not a claimed engine name limit. Thunk/target/lookup instruction signatures
are checked before activation. A preflight cannot guarantee that an engine
table is not changed concurrently before instantiation.

Both analyses completed with reader/original PTY exit0 and fresh exact original
host/parent absence plus registry0. D's owner field/outer console scope mistakes
are explained by a separate witness; original records remain unchanged. E
correctly captures both plan/reader hashes and the outer reader exit. No game,
CPP, scan, automatic call expansion or PE/dump/PDB/CDB analysis occurred.
At source merge, the new name-resolution/context-refusal native fixtures were
source-only; the corrected route had not been compiled or run in engine.
C remains failed evidence, not a measured successful body/query/destruction.

Native19 subsequently completed the full Release build and all required fixtures,
including the new name-to-object routing and early-refusal cases. The compiled
source is merged revision `f2e5362fe8c1536396d56ee14f55735374384091`, approved
code head `13473e02471d28bb027679fb161a40b9f9818c3d`, upstream revision77e6d4d.
Its 318 declared text files total 3,010,349 bytes; 36 selected native sources include 34
unchanged from Native16 and only the collision provider CPP/HPP changed.
The actual output tuple was observed inside the original build reservation:
EXE `4E8885EACBF01ACBCE57F8A3EB05A8347F06CB2A515B78516AF8FB39D37E3E9F`
(6,138,880 bytes), PDB
`1E3D97FB1C1D0F2A7CE90DCED9132D25495B9BC1EF7A7FE6413923C8BF058343`
(55,291,904 bytes), build manifest
`070A50C7670CD0FE3243C8BF8451F6EA857E7DD1DD7AB4BB76BF0DF1E605E649`
(16,536 bytes). No output executable or PDB was rehashed after release.
Pre-compiler preservation recorded 37 available managed files. The original
owned job and PTY exited 0, Active=0 was observed before disposal, and a fresh
closure witness found all original/observed identities absent and registry=0.
An auxiliary UTC-string-versus-JSON-DateTime comparison initially refused;
normalizing both creation instants to exact UTC FILETIME corrected the witness
without changing the original metadata or relaxing process identity checks.
No game, Main deployment, native creation/query/destruction or owner acceptance
is claimed by this compilation. Issue #8 remains open; the next evidence needed
is a separately admitted zero-client engine probe on this exact output tuple.

Primary consumer evidence is upstream77e6d4d `fx/engine.hpp`: the eighth
argument of `PhysicsQuery_LegacyTrace` at0x14055C9E0 is named `contentMask`;
`fx/update.cpp` supplies its brush mask in that position and provides the larger
trace scratch buffer. The provider passes1 in that same slot. The retained
retail solid path forwards the owner's contents to0x140550EC0 for existing
world0/1 instance IDs, whereas the provider sets1 on its separately created
original instance. These are distinct owners/instances and uses. This supports
preserving the new body's1/query1 pair; it does not qualify the complete engine
filter implementation or the GSC bullettrace default mask. B performed no
post-allocation query, and those remaining semantics need actual engine evidence.

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

The most recently admitted image is the separately compiled Native16 corrected source
`8f1ac6d2443feb4432bfc2f9f6915d0ba50ea0c6`, EXE
`A47E4F6464D208D612DE85E40D77E5FD106D3CB092B9029E9C4B83844C6FB7CD`,
manifest `7B7B50B703F92E4D1394D6F74836B9A7D0588FCF0B03453C5B8298C6716DFA95`
and PDB `4E7A7D0EF32431C73B1AD123C5A4D3298B905A851C2C176A791F013FC0C4D427`.
It declares `CollisionProvider=true` and 36 sources. There is no
`CollisionProbeCapability` field. The consumer pins that actual compiled tuple;
the reviewed Native16 owner-admission correction is present and shared
lifecycle/transport remain unchanged. No further C++ rebuild is required for
that attempted zero-client body/query/removal test. Its C failure is preserved
above; a new test needs the qualified argument-provenance correction. The old
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
Native14 consumer tuple ran once in B and refused before allocation as recorded
above. A further source policy requires independent review and a separately
authorized compile/run; no successful engine collision follows from B.

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
