# Protected authoritative player contact

## Readiness reference retention and console envelope - 2026-10-18

This Source candidate implements the reviewed proposal SHA-256
`F8C13AEA1F19D61CB5DAD0082DB30AF26481F89758845A524468722CF21ACE76`
on Native main `bbfed9697924d85b3668600455ccf9dc6ee50248` (including PR 78's
Aurora updates). It changes only the collision operation, its pure Core,
existing Source tests and this document. GSC, native providers and Server
helpers are unchanged. It neither adopts a new compiled consumer nor exports
a Source package. The compiled `785ddd43d18c4eebd599bab10880e83d73a950e9`
lineage and the separate Server helper lineage remain distinct.

After the existing original-session/protection and wire checks, the operation
creates one managed `CollisionReadinessBindings` record on the actual Session.
It retains the original Session, client/server identity references, validated
token, actual wire nonce and original start tick. An existing Session property
is refused rather than replaced or adopted. The same record is attached to the
original exception's `Data` before a bare rethrow, so replacing a surrounding
`RuntimeRefs` dictionary does not discard it. These are live managed references,
not an ownership receipt: the Session and record reference each other, and the
record must not be serialized wholesale or reconstructed from JSON.

The first `ErrorRecord` and its exception are retained before secondary
canonical parsing. The original refusal, type, message and exception object
remain authoritative. PowerShell can expose a different outer `ErrorRecord`
wrapper while unwinding scopes; the contract retains the first inner record
and the same exception, without claiming outer wrapper identity. Metadata
failure leaves `Generation`/`CanonicalReady` null and status `UNKNOWN`, then
rethrows the original refusal. An outer operation failure also publishes that
same record without replacing an already retained first error.

Expected generation comes only from the current canonical readiness validator:
literal PID/nonce, slot 0, protected 1, native tick within the original interval
and at most 500 ms old, plus the existing finite bounded anchor check. Failure
metadata validates the full supplied transcript and requires its selected
latest canonical publication to precede the first owned `FAIL`. It never
slices at `FAIL` or falls back past a later malformed, foreign, partial or
post-failure publication. Missing input clears a previously retained generation
to `UNKNOWN`; supplemental cached diagnostics cannot supply expectations.
Every owned `FAIL` still throws and can never return positive readiness.

The separate optional diagnostic reader accepts exactly `BODY + TAB + LF` or
`BODY + TAB + CRLF` for each of its two rows and the intervening canonical
`FAIL`. The ASCII body must satisfy the original ordered field grammar; leading,
interior, missing or doubled TABs are refused. The 384-byte wire ceiling counts
the terminal TAB and excludes LF/CRLF. The existing producer bound is 324 ASCII
body bytes, or 325 bytes including TAB. No trim or whitespace normalization is
performed. `RawLine`, original character `Offset`, `WireByteCount` (including
the physical line terminator) and `BodyByteCount` are retained for both events
and canonical `FAIL`; accepted ASCII makes character and UTF-8 byte lengths
equal. Diagnostic ticks remain strictly increasing inside the supplied
interval, with no added maximum age. This is distinct from canonical readiness's
existing 500 ms limit. Correlation remains diagnostic-only and proves no cause.

Pure Source checks cover five valid diagnostic pairs, 54 `INCONCLUSIVE`
controls, 17 missing/latest/post-failure metadata controls, same managed
references across exception unwind and `RuntimeRefs` replacement, foreign
carrier rejection, freshness and diagnostic isolation. The actual operation's
catch is exercised with synthetic originals; its Run body is not executed.
Legacy controls retain 32 first-failure diagnostic refusals, three partial and
two foreign failures, seven identity, seven readiness and 13 pose refusals,
nine Source causal mutations and hashes of all nine original GSC functions.
The operation still has one wire read, three log reads and six existing clock
references; its frozen-readiness gate still precedes arm. No new engine getter,
wire/log/clock query, retry, protection action or diagnostic arm hook is added.

E4 remains a closed historical refusal before arm, with optional diagnostic
interpretation `INCONCLUSIVE` and the cause of `none` unknown. Its consumed
readback is not reopened or reparsed by these tests. Source validation does not
qualify contact, prediction, world reset, owner gameplay or a new game run.
Next action is independent exact-head review of the private draft PR; merge,
Source export, consumer adoption and game arbitration remain separate.

## Cached readiness diagnostics candidate - 2026-10-16

E3 refused before arm with `frozen_anchor_readiness_lost`, group `weapon`,
available stamp and predicate `none`. Its original lifecycle is known closed;
F0/F1/F2 did not pass. The reason for `none`, inventory contents, prediction,
world reset and owner acceptance remain unknown. The retail intro flag precedes
later gesture/control work in the retained reference corpus, but the complete
gate had already permitted an anchor. This is a timing hypothesis, not a cause.

The cached-only candidate follows the reviewed text contract SHA-256
`31BAC865D9F862A8E291E4679A08543E813F738725299D339D67B288B65730F6`
and ingress addendum
`A629CA7870F360A228699740E59FB737E4FCBE306CD8F8FCF9C719A493C7A87D`.
It retains each original predicate's evaluated result, preserving order,
short circuits and calls. Every invocation resets later fields to `N`
(`not_evaluated`); `U` means absence actually checked by the original predicate.
The original per-iteration stamp is copied before `playable`, never queried
again. The bounded index disables diagnostics at exhaustion without changing
readiness or reusing an index.

At most two supplemental `[Collision readiness]` rows are attempted: first
anchor freeze after its original `PLAYER_READY`, and a later `none` failure
only after `fail` returns normally, including canonical `FAIL` and all owner
cleanup. All nine original functions outside `playable`/`contact`, including
`fail`, stay byte-identical to e879. If failure/cleanup throws,
the optional terminal event is not guaranteed. No new exception mechanism,
wait, input, grant, dvar activation, state getter or clock query is added.

Scalar string provenance comes from the existing native string producer and
owned token. The existing retail string primitives `getsubstr` and `issubstr`
validate bounded ASCII alphabets in memory; they do not query world state.
The fixed row has a 324-character producer bound and a hard 384-character
ceiling. Unknown/absent values suppress output. These extra memory operations,
string calls, allocations and two optional prints can affect timing or fail;
the observation is not claimed to be neutral.

`Read-IW7CollisionReadinessDiagnostic` is a separate pure optional reader. It is
not called by the operation or readiness/arm reader. It requires exactly two
complete ASCII events, original token/PID/nonce/generation/slot/protection,
strictly increasing index and native ticks in the supplied time interval,
the allowed cached states, and canonical first refusal between the events.
Missing, partial, duplicate, foreign, stale or malformed data returns
`INCONCLUSIVE`. A correlated pair proves only its recorded transition; it
cannot produce `Ready`, arm authority, contact success or a cause. In
particular, `HasWeapon` remains `N` on `none`; no inventory query is added.

Pure Source checks exercise the real reader with four valid pairs and 43
negative controls, plus nine Source causal mutations and hashes of all nine
unchanged original functions. They check ordering/counts and ASCII bounds;
they do not interpret or compile GSC. This candidate still needs exact-head
review. No native/GSC engine execution, runtime observation, new Source export
adoption, merge or Game authorization follows from these checks.

2026-10-14: **source-only, not run**. E already measured server point/actor
queries and usage restoration; it did not measure a real player's movement.
This separate fixture/operation prepares that next control without enabling
client collider creation. Client prediction, exact actor shape/margin, sensor
behavior, physical-world reset and owner acceptance remain unqualified.

`Invoke-CollisionPlayerContact.ps1` defaults to pure Plan. Without coordinates it
reports actual protected stock-pose selection pending and invents no anchor.
Optional finite coordinates are preview only: a 256 by 256 by 16 floor at
anchor Z+96..112, and initial placement at Z+208. Plan reads only its GSC source;
it creates no output, lease, process or staged game file. Coordinates are
examples only; Run rejects that preview argument. The actual fixture
must freshly verify five lower ground points and five clear vertical segments
before placement. Native actor-baseline admission adds its own existing query
guard; these controls do not prove an exact player shape or full terrain safety.

The three measured phases are separate from the two journaled initial placements:

- F0 has no body: ordinary gravity must carry the protected player through the
  future top to a stable audited lower landing.
- F1 inserts one observed native body: ordinary fall must land and stand on its
  top for 600 ms. A normal 300 ms forward input must produce 4..64 units of actual
  movement while maintaining top contact. A later normal Use press requests
  removal; release and 250 ms of observed velocity stability precede clearing.
- F2 clears the native body with `collision_clearboxprobe`, keeps the script
  owner alive for native post-removal queries and the ordinary fall through the
  former top, then deletes that owner after stable lower landing.

The pure reader requires launch-bound nonce/generation/server identity, current
native protection stamps, contiguous ordered finite movement samples, bounded
observation gaps and velocity-consistent position changes. It checks actual
falls, stable landing/contact and movement; a dispatch acknowledgement or GSC
PASS string cannot substitute. It also requires the six ordered shared usage
snapshots, native before/inside/removed point and actor controls, original body
allocation/destruction and owner-alive ordering. Shared counts are observations,
never a baseline assignment. The generation stamp binds the logical session;
it does not qualify physical-world generation.

The operation runs **inside an existing original owned session**. It creates no
process controller and never acquires/releases a lease, stages an executable or
restores game files. The separately reviewed original caller must prepare/start
one complete private dedicated/base-client group using existing helpers, then
call the operation inside its guarded try/finally. Run refuses without retained
objects, both pinned prepared source receipts, exact Native25 server identity,
original reservation host ownership and fresh protected playable client. It
verifies source files before importing those helpers. It uses existing typed
collision stdin only for the one arm command; normal movement/Use/capture use
the existing bounded scenario transport. A passive warmup binds that handshake
before measurements. A separate passive wait requires current native-stamped
playable readiness, completed retail intro flags, unfrozen controls, loaded
stock weapon and one second of stable ground before the collision arm/placements.
That readiness wait is outside the measured 25-second/30-second budgets.
A phase timing failure remains a failure, not a reason to force a PASS.

Before a run, review the entire capsule: exact final source and compiled tuple,
fixture/config/anchor, source receipt hashes, original-host entry, complete group
reservation and actual machine telemetry. Native25 is a candidate, not a promise
that this new fixture compiles/runs. New native requirements must be coordinated
with the native source owner and separately reviewed/compiled. No heavy slot is
granted by this document or the source merge. Preserve an occupied owner client,
reuse retained dedicated stock and the base client, maintain cheats=0 plus fresh
engine godmode and engine/GSC inactivity protection. The fixture uses reviewed
noncombat drain ordering and requires zero alive/pending/reserved enemies.

The operation returns **measurement only** with `LifecycleClosed=false`,
`LeaseReleased=false` and `OriginalHostExitObserved=false`. The caller must close
the exact client, verify valid empty UDP for 30 seconds, stop the original
dedicated, restore candidate/base-client/Main bank isolation, release only after
verified restoration, and observe the true original host exit separately. On
failure keep diagnostics, original handles and uncertain reservation; missing
UDP alone is not a crash. Only those later witnesses can qualify closure.

Optional standing capture needs visual inspection; it cannot prove prediction.
No Main promotion, accepted tag or owner acceptance follows from source tests.
Issue 8 remains open. Next action: independent exact-head source review and
source package/capsule preparation, then distinct Root game arbitration.

Local source validation passed: one valid narrow transcript plus 22 causal
refusals; pure Plan/missing-context refusal, six original identity refusals and
seven partial/stale/future/foreign/unprotected readiness-publication refusals;
PowerShell grammar and official pinned GSC-tool 1.5.1.359 parsing; existing D/E
transcript regression; product boundary (292 tracked, 275 exports, 3 dependencies)
and whitespace. These are source checks, not Aurora runtime compilation, native
build, player gameplay or closure evidence. Readiness tests check wire freshness
and binding, not a fabricated retail intro/control state; those engine flags
remain solely in the actual fixture's runtime readiness check.

## Current compiled consumer and caller seam

Root chose the already reviewed/compiled Native25 source
`785ddd43d18c4eebd599bab10880e83d73a950e9`, not the documentary merge revision.
Its EXE identity is `012E6CDDCD6A91ADC2F041035C86417064998127044A11341895C55F8BD4FC53`.
The [sanitized consumer tuple](evidence/2026-10-14-collision-player-native25.json)
comes from the original under-lease capture and closed build receipts. Metadata
and source checks confirm all 36 compiled inputs, modules/isolation/collision
capabilities, existing protection/input/stamp methods and collision CPP/HPP
identical to Native23. No new PE/PDB read, build or game was performed. This
consumer update changes one admission identity; E remains an older measured
episode, never relabeled as a Native25 player result.

The Ops owner retains `Agent-Lab.ps1`, its original host and lifecycle helpers.
Its `RuntimeRefs` are published in `finally` before cleanup, so they cannot be
used as a live-session service after return. Future integration needs an exclusive
collision branch inside that existing caller, before its `finally`, staging
only this fixture/config and borrowing its actual session/server/identity objects
directly. Never reconstruct handles from JSON/token or add a process controller.
The existing caller keeps its complete reservation, base-client lock, exact
process identities, bank/Main audits and ordered cleanup/restoration. Coordinate
the caller's own changes with its owner; the collision operation owns measurement.

Actual anchor selection and this caller branch remain source work, not runtime
qualification. No coordinate from an unrelated rendering scene or AABB oracle
is accepted as a safe physical location. A reviewed source reference/selection
must produce explicit coordinates, followed by the fixture's fresh clearance
audit before the two declared placements. A capsule and separate Root game slot
are still required.

## Frozen actual stock pose

The fixture uses the real protected player's ordinary stock-spawn origin after
actual retail readiness checks. It freezes that position once for the unique
token and publishes its coordinates with the current native PID/nonce/generation/
tick stamp. A lost player/readiness or position change over one unit invalidates
the frozen proposal before arm. The operation derives and records the explicit
actual plan from that publication, then rereads freshness, generation and
unchanged coordinates immediately before its one typed arm. There is no fallback
coordinate, E altitude, arbitrary memory getter or new native binding.
`paris_collision_player_anchor_current=1` is required; legacy coordinate config
is no longer consumed.

The five ground/five clear segment audit still runs against the actual frozen
pose before either journaled placement. A spawn area which cannot pass the audit
refuses the experiment; source tests never fabricate its location/terrain. The
operator writes a local actual-anchor plan before arm for the original caller's
evidence. Optional explicit `-Anchor` remains pure preview; live invocation omits
it. Seven ownership, seven readiness and thirteen pose transport/freeze refusals,
plus existing movement tests, check the source contract without qualifying a game
location or player movement.

The independent source review found a partial-line fallback in the earlier d8e
candidate: a fresh completed publication followed by a newer incomplete own
publication could still return the predecessor. The reader now returns pending
until that own row terminates; complete malformed/foreign own rows still refuse.
Three causal cases include a valid predecessor plus partial malformed/foreign
ready or failure rows, with separate unrelated-prefix/foreign-token noise controls. This is wire
validation only. The rejected source candidate remains in history and was never
run in game.

## Readiness-loss diagnostics — 2026-10-16

One separately admitted, subsequently closed episode using operation a572,
Server helper 3d514559 and compiled candidate 785ddd43 refused before arm with
`frozen_anchor_readiness_lost`. Its single bounded owned-log extraction contained
one READY, fifty PLAYER_READY publications spanning 2437 ms with the same frozen
anchor, then that failure; no AUDIT, PLACED, SAMPLE, CREATED or DONE was present.
The episode's original owner handle fields were zero, its client lock SFH was
closed, and its transactions and Main/bank audits reported restoration. Kernel
CloseHandle returns were not measured. The original host exited and independent
checks found no episode processes or leases. These qualify that episode's closure,
not contact, a fresh protection stamp at arm, or a physical-world reset. The
underlying lost predicate remains unknown. Existing frozen packets and evidence
are preserved; they are never relabeled or replayed.

The fixture now records the first failed readiness group during its original
evaluation. The order remains safe, ground, the two eager weapon/velocity
getters, weapon, velocity, intro screen, intro gesture, controls and hostmigration.
Both eager getters still execute before the weapon test, including when that
weapon is invalid. The diagnostic resets on every evaluation, calls no getter
again, and does not repeat protection or native stamp queries. Stamp state comes
from the same already captured value. Only the existing frozen-readiness FAIL
adds the bounded group and stamp-state fields; its reason and fail-closed path
remain unchanged.

The production reader still rejects every complete owned FAIL before considering
any ready publication. It reports only allowlisted, bounded reasons/details in
the exception message and Data. Unknown, malformed, incompatible or oversized
diagnostics remain generic refusals; foreign-token and incomplete-line handling
retain their existing behavior. It never falls back to an earlier Ready or a
later, more convenient failure. Detection retains the original PowerShell
case-insensitive FAIL/prefix/token semantics; diagnostic parsing remains strict.
Source candidate 381ff93 accidentally changed detection to case-sensitive. Review
reproduced fallback to a preceding Ready for a mixed-case prefix or uppercase
token. It was rejected before adoption, and the corrective commit preserves it
in history with both production-reader causal refusals.
No timeout, freshness limit, frozen pose,
protection/privacy condition, controller input or F0/F1/F2 measurement changed.

Validation is limited to PowerShell grammar, production-reader causal tests and
GSC source ordering/count comparisons. No substitute GSC interpreter, official
GSC-tool invocation, engine compilation, native build or game is part of this
change. Current Server callers retain their old hash-sensitive pins; adoption
needs separate owner review, a new prepared source/capsule and a distinct fresh
Game authorization. The next runtime must establish its own admission and
protection rather than inherit this closed episode's metadata.

## First weapon-predicate diagnostic — Source only

The separately authorized E2 episode reached the diagnostic fixture and refused
before arm with `frozen_anchor_readiness_lost`, group `weapon`, stamp state
`available`. Its original exception retained these allowlisted values. The
snapshot contains no cached weapon value, so the rejected sub-predicate remains
unknown. The three actual transactions reported restoration, Main/bank audits
reported no static change or bank delta, original owner handle fields were zero
and the client lock SFH was closed. Root observed the original host's true exit
and independently confirmed all four identities and leases absent. These are
failed-episode closure observations, not measured kernel CloseHandle returns,
direct internal Source-guard closure, fresh GOD/BOUND at arm, or contact evidence.
E2 and its frozen inputs remain consumed and immutable.

The next Source diagnostic divides only the existing weapon conjunction into
its four original expressions, unchanged and in order: `isdefined(weapon)`,
`weapon != ""`, `weapon != "none"`, `player hasweapon(weapon)`. A false result
still returns false immediately. The local weapon and velocity getters both
execute once, in that order, before the first expression; hasweapon executes
only if the preceding three expressions succeeded. No comparison is converted,
getter is repeated or protection/native API is added. The private diagnostic
resets on every evaluation and records the first false label from that same
cached weapon: `undefined`, `empty`, `none` or `not_owned`.

Only a frozen-readiness failure in group `weapon` appends the optional
`weapon_predicate` enum. No raw weapon name, object, handle or identifier is
published. The reader accepts the field only with that reason/group and adds
the bounded enum to its exception message and `CollisionWeaponPredicate` Data.
Legacy E2 failures remain readable refusals. Unknown, malformed, duplicated,
incompatible or oversized fields remain generic refusals, with the first complete
owned FAIL still winning over all Ready/later failures. IgnoreCase detection,
the 384-character diagnostic bound, partial/foreign handling and all existing
measurement/admission rules are preserved.

Tests exercise the production reader with text fixtures and existing IO doubles,
plus GSC Source ordering, short-circuit structure and getter/reset counts. They
are not a substitute GSC interpreter or engine/Game validation. No GscToolPath,
native tool, build, runtime log, lease or Game is part of this Source change.
Further execution requires separate exact consumer pin adoption, reviewed new
inputs/capsule and a fresh Root Game authorization; no frozen episode is replayed.
