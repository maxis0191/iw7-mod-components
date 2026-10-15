# BO3-style Zombies HUD adapted to IW7 — source prototype

This client module is an authored IW7 LUI implementation. It is not a retail BO3
HUD import, a screenshot overlay or a complete qualified replacement yet.
The requested destination is a complete HUD adapted to IW7 characters, perks,
weapons, quests and states. Content0.16.0 fixes the fan probe's publication
contract after actual0.15 emitted common fields without its detailed sample.
The visual cause remains unknown. The0.14 art, dimensions,
ownership and restoration remain unchanged. The0.13 native-action underlay retains the actual localized title,
progress, stencil and native visibility.
The0.12 selected-card identity surface, native name/icon presentation and0.11
angular charge panel are retained; the actual-player team layout remains Source-tested;
the coverage matrix below remains the completion contract.

## Ownership and loading

Client Lua lives in `src/ui_scripts/bo3_zombies_hud/__init__.lua`. Generic native
hooks/weapon work and SDK core remain separately owned. The server recipient
owns `ops/BO3-HUD.Profile.Core.ps1`, its preview and scoped rollback. UI bitmaps
and converters remain with the material/asset owner; no retail dump is shipped.

Existing source77e loads `ui_scripts/<single-folder>/__init__.lua` from scoped
disk search paths, then LuaFile assets. Disk module names take precedence over
same-name FF assets. The existing HKS generation guard cancels old scheduled
callbacks. This prototype needs no new CPP hook or FF. Its namespace/bounds and
transaction differ from both the old 1600-byte HUD lab and immutable BO3Static.
Never overwrite updater-owned cdata or use global cg_draw2D suppression.

The existing private recipient profile is the explicit opt-in authority: the
fixed file `iw7-mod/bo3_zombies_hud_lab.cfg` must contain exactly the two lines
`set bo3_zombies_hud_enable 1` and `set bo3_zombies_hud_private 1`, each followed
by LF, UTF-8 without BOM. It is 59 bytes, SHA256
`C14B18C6193C7864CED9C6F5B3A5C3ABEC8C24EE13263A7781CA671C14F68C8A`.
Absent or changed bytes prevent new binding; no other file is read by this gate.
The module never writes dvars/models. At source77e, startup +set for an absent
dvar only queues an on_register callback; neither HUD opt-in has a native
registrar. Thus startup arguments alone cannot qualify the raw engine values.
Those actual values/types are diagnostic, separate from private profile approval.

The active scene must be nonfrontend and Engine.IsAliensMode, as the actual
HudManager selects its Zombies classes. A private dispatcher installs immediately,
also retries after table/function replacement, and an owned CreateHud hook runs
after the original constructor. Already built roots are visited through their
actual wrapper `_widget` leaves. Stock subscriptions and visibility parents,
unrelated constructors and CPHUD/ZMHUD classes stay intact. Shutdown restores
only hooks that are still ours. Cosmetic nodes retain references for the stock
callbacks while detached; normal VM teardown owns their final disposal.
Existing instantiated widgets require normal HUD/VM teardown; no hot-reload
restoration claim. Close the owned client before file/profile rollback.

## First real HKS failure and source correction

The first frozen native903/caller255 V2 test loaded the module in the real VM,
reported no HKS/factory error, and completed protected fire/reload/restoration.
Root and the caller owner independently inspected three authentic frames and
found the stock IW7 HUD only. Loading is qualified; replacement pixels are not.

Source review confirms native HKS startup calls the original before custom
scripts, while the old module installed only a deferred, future-factory hook.
It had no path to restyle already-created essential leaves. Retail AddWidget
also returns a wrapper whose `_widget` is the actual container. Shrinking the
round wrapper incorrectly resizes its full-screen canvas. Version0.2.0 adds
immediate/post-construction/live-root paths and changes the round leaf only.
The raw engine opt-in values in that failed run were not measured; their absence
is not asserted as an observed runtime fact. The native registrar gap is source
evidence. Native903 and its failed frames remain unchanged.

The subsequent frozen native0bb/caller257 V3 run measured actual engine string
values1/1, profile1/frontend0/cp1, owned hooks and a concordant ZMHUD bind. Its
authentic spawn/spent/reloaded frames show partial custom round/ammo styling,
but a clipped portrait, overlapping cash and a Fate-card demon/fan covering the
reserve area. Ten perks were visible while bind reported perks0. This qualifies
partial custom effects, not a clean layout or a complete replacement. The V3
tuple, frames and restoration evidence remain frozen; the exact identity of the
second visible cash glyph group was not measured and is not asserted.

Version0.3.0 responds to those observed failures with Source changes:

- Reparent the one original local PlayerIcon/PlayerCash pair into an owned hero
  inside the same MainPlayerInfoContainer. Reset their inherited scale/rotation;
  retain the actual image/status/cash subscriptions. Quest children keep their
  original parent, references, positions and models. No second total is created.
- Reuse PlayerCash's original three-row CPPlayerInfo grid, native row assignment,
  refresh timer and portrait/status callbacks. Expose actual names and currency;
  never substitute scoreboard score for currency or fabricate teammate rows.
  Complete scoreboard rows provide mic flags by matching their real clientNum.
  Unknown flags hide only the added mic glyph. Spectator identity uses the same
  native target selection as CPPlayerInfo.
- An owned post-RefreshRows hook applies layout/hero identity after the original
  returns, including newly created rows and after the bounded startup poll ends.
  It preserves every return value, retires superseded wrappers and restores only
  its own assignment at shutdown. No extra recurring timer is installed.
- Give the full FateCardWidget a separate region above ammo and left of the
  active-card column. The retail fan reaches y588.5 beyond the declared389 height;
  sizing from the demon alone still overlaps ammo. Deck/charge/arrows/selection
  and visibility callbacks remain native. Cash deltas keep their flight/fade in
  a separate horizontal lane; they are not hidden or replaced by the total.
- Traverse wrapped perk leaves with explicit depth5/node128/icon16 bounds, while
  retaining the original toggle-list ordering, images and lifetime.

These are source geometry and callback guarantees. New HKS captures must verify
safe-area placement, long names, all card states, remaining quest overlap and
actual one/four-player behavior. Full HUD coverage remains open in
[server issue247](https://github.com/maxis0191/iw7-paris-server/issues/247).

## V4 real solo result and compact-deck Source follow-up

The frozen UI0.3/native0578 + Ops259/6ba06e V4 case
`20261015-003031-413-babf121e` produced three authentic1280x720 native BMP frames.
Root, Ops55 and the UI owner independently viewed them. The portrait is whole,
the actual name and one25000 total are visible, and clip/reserve changes are
12/48 to11/48 to12/47 with the Kendall name readable. The deck no longer covers
ammo. Crosshair and actual interaction text/key/price remain visible. Initial
perk count0 is transient: Ops55 reports count10 after input. Perk images remain
retail artwork; style-call counts do not prove new artwork.

The large demon/fan still floats at mid-right. The native ticket/souvenir+0 is
close under the total. Real solo improvement is confirmed; cooperative, other
maps, revive, owner acceptance and complete BO3 composition are unqualified.
The Ops owner retains the original logs, closure/restoration and PTY evidence;
the UI review is pixel evidence for these three frames only.

Version0.4.0 leaves the frozen0.3 package/case intact and changes only the deck's
whole-group transform. Native fan, on-deck card, charge/readiness, arrows, fire
feedback, selection animations and every model callback remain in their original
hierarchy. No child is hidden, detached, replaced or given a new alpha. Native
active-card effects/timers remain at their existing size in WonderCardFillWidget.

The deck retains its declared253x389 size and receives a scale delta-0.35
(65% size), at right offsets-420/-167 and bottom offsets-695/-306. In the candidate
center-origin geometry the maximum native fan y588.5 becomes bottom-244.4,
above ammo's top-210 by34.4 source units. This is a Source layout calculation,
not measurement of a new HKS frame or proof that small card glyphs are readable.
The next separately authorized capture must check every card-count/readiness/
selection animation, active-effect coexistence, arrow/charge readability and
screen margins. Equipment/power-up/down/revive/quest composition remains open.

## Equipment, status and inventory Source0.5

This lot uses the existing HKS widget/model contracts at the same pinned retail
reference, not reconstructed gameplay logic. Existing and fourteen additional
small text references cover the five MainPlayerInfo variants, revive containers/progress/
header, LastStandTimer, afterlifeSelfReviveProgress, ability base and crafted
weapon. Their Git blobs and SHA256s are retained outside Git; no dump is shipped.
The frozen0.3/V4 and0.4 Source packages remain unchanged. No new game, CPP, FF or
asset generation occurred for this lot.

| Information | Source arrangement | Native authority retained |
| --- | --- | --- |
| Primary/secondary offhands | Two rows to the right of ammo, clear of the deck; larger ability group and24-unit quantities | Original icon/data source, numCharges, independent iconAlpha/numAlpha, color and PlayerAbilityWarning animations; no new glyph/control |
| Crafted/Mule/infinite | Badges and crafted control label have separate lanes beside ammo | Crafted image pulses, PC empty-menu-stack/DLC4/controller text, Mule model alpha and unlimitedAlpha; numerical ammo visibility stays native |
| Active power-ups | Upper status rail; original list unrotated, existing/fresh cells52 units with inset runtime images | activePowerups, activePowerupBits, activePowerupAnimationBits, ordering/add/remove, FadeIn and Flash events; no fake duration |
| Power-up activation | Name uses the shared bold font; remaining popup geometry stays native | UIMessageQueue, actual icon/name, flight, scale, completion and simultaneous messages |
| Revive/secure progress | Center rail below aim; pale native header and muted-gold fill | secureState/secureProgress, original SetHeader measurement, SetProgress clamping/mask, Show/Hide and Skeeball; no mask anchor write |
| Downed timer | Native countdown/icon move to a separate center-right region;36-unit count in a48-unit text box | zm_ui_laststand_end_milliseconds, original setEndTime and visible/default parent transitions, including late binding |
| Afterlife/self-revive | Shared title font/color, original full-width canvas | Soul progress, token/arcade models, message/controller glyphs, Bootup/ShowTokenMessage and native geometry |
| Quest/Rave/chi/element/inventory | Remaining original MainPlayerInfo group moves to an inventory shelf away from hero cash; DLC3 element label enlarged for the group scale | All original children, hierarchy, per-map masks/images/text, fuse/inventory alphas, Rave fill and other callbacks; no synthetic inventory |

The inventory parent uses a282x219 target size at left650/right932,
bottom-260/-41 within its original container, with scale delta-0.25. Portrait and
cash are already separate original objects in the hero. This moves the whole
native quest group, including the Spaceland ticket/souvenir that was too close
under cash in V4; unknown children are kept with it. It does not reparent those
quest leaves or overwrite their masks/alpha. DLC3's actual element text remains
model-owned. Native DLC2 originally declares282x196; the adapter explicitly sets
the common target. V5 below qualifies only its observed solo states. Other
positions/scales remain Source proposals pending readable crafted controls,
inventory/status overlap, safe area and every map/state. The fixtures exercise five class aliases
and controller indices0..3, not five real map runs or four-player acceptance.

## V5 observation and next art separation

The frozen UI0.5/native3d3b + Ops262 case
`20261015-021207-104-cdd2c7bc` has a durable
[V5 server record](https://github.com/maxis0191/iw7-paris-server/pull/263).
Root, Ops55 and the UI owner viewed all three original1280x720 BMPs. They show
a smaller deck, one25000 total, a separated ticket+0, visible DC star, one grenade
with count4, and clip/reserve12/48 to11/48 to12/47. Actual interaction text/key/
price and crosshair remain visible. The transient white circle/blue500 matches
the native interactionNotification cost widget by Source and pixels; its exact
runtime widget/entity/model was not captured. It qualifies no power-up state.
Ops/Root closed and restored the case; the UI review alone is pixel evidence.
Secondary/crafted/Mule/infinite, power-up/expiry, down/revive, other maps, real
cooperative/controller and owner/full-HUD acceptance remain open in issue260.

The next step is a small art-layer adaptation. Mechanical information requires
equivalent identity and state cues; it does not require IW7-specific pixels.
Current native artwork is the fallback until its replacement preserves those
meanings. Six further pinned text references (28971 bytes, external blob/SHA
receipt) distinguish these roles:

| Visible layer | Required information/behavior | Safe next surface and boundary |
| --- | --- | --- |
| Perk images | Actual data.icon, list/order/grant/loss and perk identity | Authored frames now; replace each icon only with a verified IW7 identity-to-adaptation map; keep unknown icons native |
| Selected card | Runtime consumableDeckSelectName/Icon/Backing and native selection/activation | Preserve name/icon and dynamic backing until each role/value is mapped; add an authored frame under the same parent |
| Fan backs | Two static images fanCard/fanOverlay; parent animation carries count/depth/pose | Source0.6 replaces their art with authored flat backs/rims, retaining the same image objects, parent pose/count/selection and native overlay depth tint/alpha |
| Charge and ready effects | radialAlphaLarge.circleFill uses dpadUpFillPercent; native ready/glow/arrow behavior | Keep progress/mask/segment materials and callbacks; adapt the surrounding frame without covering the meter or glyphs |
| Demon faces | Jaw Chomp reacts to fill; sadDevil signals zero cards; head becomes Mephistopheles in DLC4 mephBattle | Source0.7 uses actual count/state and known BOSS title, retaining meter/glows; unresolved state falls back to native art |
| Active-card effects | Runtime icon/name/fill and actual lifetime | Preserve identity and radial progress; change a surrounding frame only |

Source0.6 implements that first surface-only step. The two original fan image
objects use the existing white material, with a dark backing and five original
rim/rule rectangles. The inset20.5/212.5/80/432 stays within their original
quad-11.5/244.5/0/512; its center is retained. Parent geometry/rotation/alpha and
all native card-count/selection animations stay unchanged. The native overlay's
depth tint/alpha is not overwritten. New factories and existing four fan widgets
are adapted once, with no duplicate rim nodes on subsequent root polls.

The demon is intentionally unchanged in this small lot; its appearance remains
part of the replacement objective. An unconditional hide would remove meaningful
empty/boss feedback. The next core should express those states using a new
presentation: actual remaining count, existing charge and ready feedback, and
an explicit known boss indicator. A normal-state core can initially fall back
to native boss/unknown-state presentation until that alternative is validated.
Source controls should check those real feed transitions and fallback ownership;
original HKS frames must then check the visible footprint/readability. Perk
identity remapping follows an actual material inventory, without guessing BO3
equivalence for IW7 mechanics. Equipment, power-ups, revive, quests and controller
paths remain untouched by this proposed art work.

No bitmap gap is demonstrated by this inventory. Flat frames and backs use
the existing native white material and authored Lua shapes. A later generated
bitmap would be an original BO3-inspired adaptation, never an authentic BO3
texture; a design preview would not count as an in-game capture. Source0.6 has
no HKS/raster proof yet and authorizes no new Game/CPP/FF operation. Its authored
backplates replace generic IW7 fan art; perk identity images, selected-card art
and the stateful demon remain native pending the next mapped adaptation.

## Source0.7 card core and state fallback

The next mapped step now replaces the demon's visible center when the required
values are known. An original text core shows the actual remaining count and
EMPTY/CHARGING/READY. A known DLC4 mephBattle1 shows the explicit BOSS title;
normal known state shows CARDS. These are read-only presentations of existing
feeds, not invented inventory or a new boss detector.

| Feed or condition | Required known value in Source0.7 (readiness extended in0.9 below) | Ownership |
| --- | --- | --- |
| consumablesRemaining | Integer0..5 | Original count/list callbacks plus a new read-only count subscriber |
| dpadUpFillPercent | Finite0..1 | Original radial circleFill:SetProgress remains authoritative; the new view never writes progress |
| consumableDeckSelectReady | Numeric0/1 | Original glows/ready/refill/arrows remain; new status text reads the same value |
| CONDITIONS.IsDLC4 | Actual boolean | Same native predicate used by the original widget; no guessed map identity |
| dlc4.mephBattle on DLC4 | Numeric0/1 | Known1 becomes BOSS; missing/other values use the native presentation |

Only devilJaw/devilHead/sadDevil move into an owned same-canvas ancestor. Their
original order, objects, images and animation references remain alive. Known
state masks that ancestor and shows the new count/title/status; native circles,
radial masks/progress, glows, card names/icons/backings, fan poses and input paths
are untouched. Their parent still owns whole-widget visibility/selection/scale.
This replaces the jaw/sad/boss pictures with explicit count/state/boss reading
while retaining real meter movement and original ready/refill feedback.

Unresolved values/predicate reveal the original images and hide the new view.
No nil-to-zero boss inference or clamped/fabricated count is allowed. Controller
or feed-object identity changes disable that view until normal HUD recreation;
the adapter does not retarget the original constructor's callbacks. New model
subscriptions belong to the owned view; weak ownership avoids retaining an old
root through a module table. Shutdown reveals the native image ancestor and
hides this view; complete styled-HUD rollback still requires normal VM teardown.
No extra timer or bitmap is added.

The title/count/status coordinates use the native meter center. Their readability,
boss/empty/ready/refill appearance, unknown-state fallback, parent fades and all
map/controller transitions have no real HKS/raster acceptance yet. Native art is
an intentional temporary fallback for unresolved state, not the final visual
goal. Perk identity remapping and remaining selected-card art are still open.

## Bounded binding diagnostics

Since content0.8.0, `VERSION` is separate from `DIAGNOSTIC_VERSION=0.7.0`. Every
current initialization emits `module version=0.7.0 content_version=0.16.0 instance=... initialized=1`.
Every versioned marker uses the diagnostic contract version. The content version
is informational; exact Lua bytes/SHA256, Source commit and profile plan identify
the authorized content. A compatible authored skin needs no new Ops enum entry.
A real grammar/semantic break still requires a separately reviewed contract;
there is no wildcard, inferred version or dynamic protocol negotiation.
The alphanumeric instance tag is local to the module object; it is not a globally
unique native VM identifier. Reset the parser epoch at every module delimiter,
even if an address/tag is reused. All later markers carry the same instance.

- `gate`: exact profile approval, frontend/CP booleans and raw engine values/types;
  `empty` encodes an empty string. A frontend/cp0/profile0 gate is not fatal.
- `hook`: `kind=dispatch|create_hud installed=1`, proving assignment only.
- `root`: a real allowlisted root id, actual controller and positive `root_seq`.
  The counter identifies that root object within this module epoch.
- `bind`: same root/controller/sequence, `round=1 ammo=1 portrait=1` and the actual
  count of perk icons styled. Existing subscriptions are retained. This proves
  completed essential style calls, never pixels; every marker says `pixels=unverified`.
  It does not certify equipment, power-ups, down/revive or quest coverage.
- `binding_failure` / `factory_fallback`: bounded reason and `retry=1`; transient
  missing leaves may recover. A binding failure clears prior bind evidence and
  recovery emits a fresh bind. Require the latest valid CP gate and concordant
  root/bind before capture; do not aggregate an older VM/root's markers.

Markers emit only on state changes; startup polling remains bounded. No player
names, balances, GUIDs or credentials are emitted by these diagnostics.
The grammar is unchanged from0.2.0.
[Ops262](https://github.com/maxis0191/iw7-paris-server/pull/262), merge442130b5,
extends the exact-per-case allowlist to0.2.0/0.3.0/0.4.0/0.5.0 and retains
default0.2.0; cross-version markers are refused. The added factory key
ZomPowerupIcon does not certify placement. Source0.6 adds FateFanCard and0.7 adds
FateCardDevilWidget as factory-key values, with unchanged marker grammar. An
adapter can return cleanly while intentionally keeping a native core fallback;
factory_applied/bind does not prove this new presentation or known core feeds.
[Ops264](https://github.com/maxis0191/iw7-paris-server/pull/264) is that reviewed
extension: it accepts exact diagnostic contracts0.6.0/0.7.0 in addition to the
older cases, with the same default0.2.0 and cross-version refusal. Its parser
already accepts bounded extra module fields such as content_version. Content0.13
uses the existing explicit BO3HUDDiagnosticVersion0.7.0 setting. V3/V4,
Source0.4, V5, Source0.6 and Source0.7 stay frozen, including all inputs/frames.

## Actual0.7 result and Source0.8 core follow-up

The three original1280x720 BMPs in case `20261015-032243-766-191d0100` were
independently viewed by Root, Ops55 and the UI owner. Portrait/cash/round/ticket,
equipment and actual12/48 to11/48 to12/47 ammo remain readable. Pale fan/rim
lines are visible, but neither the intended backplate identity nor custom core
is qualified: the native demon/ring remain and no CARDS/BOSS/EMPTY/READY/CHARGING
label or custom remaining count is readable. Essential bind and factory_applied
do not qualify that missing presentation. The captured logs contain no actual
card feed values, eligibility reason or core mode; missing measurements are
not measured nil/zero values. The closed/restored case is retained in
[Ops265](https://github.com/maxis0191/iw7-paris-server/pull/265). No identical
replay is requested and issue260 remains open.

Source0.8 fixes one demonstrated logical overconstraint, without claiming it
caused that run. With a known boolean false IsDLC4 predicate, CARDS needs only
remaining/fill/ready readers, pointers, subscriptions and stable identities.
An absent boss object or boss pointer is irrelevant on that path and is never
read or required. On actual DLC4, the original known0/1 boss value, valid pointer
and subscription remain mandatory. Unknown predicates, invalid counts/fill/
ready/boss, unexpected native structure/parents and controller/required-feed
identity changes still retain Native. A later predicate change also returns
Native until it matches the constructed core's classification or HUD recreation;
it never silently enters a boss view without the required subscription.

One optional `core` console trace now records the decision stage/reason, local
controller and module-local widget sequence, observed feed types/bounded values,
shape/parent bits, pointer status and mode where inspected. Unread values say
not_read; boss outside known DLC4 says not_required. False remains a measured
boolean false, not nil. Values have at most40 ASCII token characters; unsupported
types are labelled unsupported without invoking their tostring metamethod.
Only a stage/reason transition emits a snapshot: fill/count changes in the same
branch do not stream values. Each widget permits32 transition records plus one
suppression notice. Weak-key records retain no widget. The existing factory/
refresh/model callbacks own all calls: no new timer, model write, inventory input,
native hook or runtime API is added. Shape/pointer/parent fields say not_checked
when uninspected; preflight_ok describes the original pointer check. The trace
is ignored by the existing essential-bind parser and never qualifies pixels.
No0.8 HKS/game/raster acceptance is acquired by these Source changes.

## Actual0.8 refusal and Source0.9 retail readiness

The closed0.8 case `20261015-052934-332-f36dcefa` loaded the fresh content0.8
module with diagnostic0.7. Root, Ops55 and the UI owner viewed three original
1280x720 frames: portrait/cash/round/equipment and12/48 to11/48 to12/47 ammo
remain readable, but the demon remains and no custom core label/count is
positively identified. The single core snapshot reports ready_value refusal:
boolean false map predicate, numeric remaining0/fill0/ready-1, boss not_required,
shape11111, pointers/parents/mode not_checked. It precedes owner construction.
Its deduplication records branch changes, not every value or frame; it does not
prove these values stayed fixed all run or explain the older0.7 case. Essential
bind and three scenario assertions passed; optional core/full-HUD pixels did not.
Ops/Root own direct closure evidence; the UI owner read the preserved restored
result and closure receipts without making another runtime/process query.

The exact model is a direct Omnvar source, with no Lua conversion:
[InGameCoopDataSources at pin2305708](https://github.com/deshayu/iw7-dump/blob/2305708efff4227ba7cb14495ff2c31bcf6e53cf/ui/utils/cp/ingamecoopdatasources.dec.lua#L1725).
The [retail CP declaration](https://github.com/deshayu/iw7-dump/blob/2305708efff4227ba7cb14495ff2c31bcf6e53cf/cp/omnvars.csv#L145)
sets initial/minimum-1 and maximum30. The targeted decompiled
[card controller](https://github.com/deshayu/iw7-dump/blob/2305708efff4227ba7cb14495ff2c31bcf6e53cf/scripts/3417.gsc#L174)
initializes the deck and starts charging without writing ready0. An empty deck
can return after remaining0/fill0; otherwise meter-full starts the ready1 path.
Reset/consumption write0. The
[HUD refresh](https://github.com/deshayu/iw7-dump/blob/2305708efff4227ba7cb14495ff2c31bcf6e53cf/scripts/cp/gametypes/zombie.gsc#L1600)
pulses20 before restoring0/1. Thus-1 is a legal default that may persist before
first full meter, not a proven universal unavailable state or corrupted0.
Even ready1 does not guarantee every input is currently permitted: the original
controller still performs its own denial checks. Source0.9 preserves those.

| Actual readiness | New local presentation when critical state is known |
| --- | --- |
| Integer1 | Existing READY label; native feedback remains authoritative |
| Integer0 | Existing CHARGING label; no charge value is fabricated |
| Other integer within-1..30, including initial-1 and refresh20 | UNKNOWN status; actual count/title remain visible |
| Actual remaining0 with any legal readiness integer | EMPTY, independently of readiness, as in the native count branch |
| Nil, wrong type, fractional, NaN/infinite or outside-1..30 | Retain Native; the legal integer domain does not validate arbitrary data |

Only the readiness meaning becomes local. Actual count0..5, finite fill0..1,
known map predicate, original shape/parents, required model readers/pointers/
subscriptions/stable identities and strict DLC4 boss0/1 remain required.
Readiness transport is still required for an owned live subscription; it is not
silently dropped or retargeted. Known non-DLC4 still skips the boss feed entirely.
Only the same three native faces are masked; radial/rings/glow/Fire/arrows,
original callbacks, selection/input, parent fading and real values stay intact.
No model/Omnvar write, normalization to0, card input, timer, tree crawler, new
native hook, asset or Ops contract is added. The bounded optional trace retains
the real type/value and can report custom unknown; it never certifies pixels.
The next separately authorized case must verify the actual count plus EMPTY or
UNKNOWN on the genuine sentinel path. No0.9 Game/HKS/raster or owner acceptance
is acquired by the Source patch.

Reference bytes remain outside Git; no decompiled body is shipped. SHA256s:
CP omnvars12456B/f15f6656b31633054e892b4965d9acaca1051498bb2470adc24d3048a7ec9da4;
model112038B/16d6d198a19c4615023b55d78bf3f74dce8c493fdfbe472a138450f38817fe44;
card controller127414B/fb2b3f029bb173375be9adf230d7ecb1f6dc4ea6dab87128dd4bdc419245ab21;
gametype47542B/b75a4d0327c3efb015befbd0da6bf7bc1cae083359a3210c0bf8cae37c863bc1.

## Actual0.9 pixels and owned status clearance Source0.10

Case `20261015-060409-854-5006e581` loaded actual content0.9/diagnostic0.7.
Root, Ops55 and the UI owner viewed three original1280x720 BMPs: CARDS and the
actual count5 are clearly visible; UNKNOWN is identifiable but small/overlapped
with deck text/graphics. The central demon face seen in0.8 is no longer visible
at the circle center, while native card artwork and intentional rings remain.
Ammo12/48 to11/48 to12/47, portrait/cash/round/equipment, prompts and crosshair
remain readable. This is a limited real custom core gain, still a hybrid HUD.
No nickname or original image/log body is committed.

The two snapshots report custom/empty0 then custom/unknown5 with ready-1,
known false map predicate, required pointers and owned parents. EMPTY/count0
is trace-only; all three frames already show5/UNKNOWN. Neither continuous feed
history nor ready0/1/refill/activation/boss/cooperative coverage follows. Ops
preserved a restored result and actual same-host/true-PTY/fresh closure evidence;
the UI owner read those receipts without another process query or runtime action.
No full-HUD, all-art-removal, owner acceptance or retroactive0.7 claim is made.

Source0.10 changes only BO3CardStatus's owned text size and bounds: font26 to32,
same horizontal center84.5 with width164 to224 (x-27.5..196.5), and y174..202 to
y274..312. Its center moves down105 source units to a separate status lane.
It remains a child of the same BO3CardCore view, so Native fallback and parent
visibility ownership remain intact. Title/count, legal readiness values, all
subscriptions/callbacks, three-face mask, rings, selection/Fire/input and native
card name/art are unchanged. No extra native leaf is hidden or reparented.
The known FateCardOnDeck.name carries card identity; its presence in Source
does not prove it owns the exact overlapping pixels in this case. No speculative
masking or tree crawl is introduced to remove it.

The geometry is a Source proposal, not a newly measured clear lane. A separately
reviewed/authorized capture must verify the new status is visible, unclipped and
clear of native card text/art plus equipment/ammo at the actual resolution and
pose. Other card poses, maps, controllers and safe-area variants remain open.
No0.10 Game/HKS/raster, new asset/FF/native build or Ops contract is acquired.

## Source0.11 original charge panel with native feedback

The next Source lot replaces the static circle backing, radial charge picture
and two hoop pictures as a complete bounded charge presentation. The existing
CARDS/BOSS title, actual count and EMPTY/CHARGING/READY/UNKNOWN text keep their
0.10 bounds. An authored angular open frame surrounds the count; a continuous
linear rail shows the validated `dpadUpFillPercent` from0 to1. Zero fill has no
visible filled quad. Empty inventory suppresses that quad without resetting or
writing the real fill. READY also has a pale fill cue; other legal ready integers
retain actual progress and UNKNOWN text without an invented ready meaning.
This is original LUI/white-material art, not an authentic BO3 texture or bitmap.

The extra replacement is conditional on the pinned native widget's exact nine
direct children, identities, parents and painter order: Circle, blueGlow,
radialAlphaLarge, innerRing, outerRing, glowRing, devilJaw, devilHead, sadDevil.
One fixed sibling check proves this canvas; there is no descendant lookup,
whole-HUD crawler, name heuristic or new native API. An extra, reordered or
foreign-parented child leaves the original gauge untouched and uses the existing
0.10 count/face presentation. It is not an essentials binding failure.

| Native role | Source0.11 treatment |
| --- | --- |
| Circle backing | Same image/reference under an owned same-canvas backing ancestor; masked only while the new frame/rail is valid |
| Radial charge plus inner/outer hoops | Same original objects, circleFill child, materials and native progress/alpha callbacks under a separate same-canvas ancestor; equivalent linear fill replaces their rendering |
| blueGlow refill / glowRing readiness | Original objects, materials, animation sequences, alpha/scale/position writes remain visible and in their original painter order; the new frame adds no opaque cover |
| Three faces | Existing owned face mask and actual count/state/BOSS equivalent remain; no further face meaning is guessed |
| Selected/active cards and controls | OnDeck identity/name/icon/backing, fan pose, Fire/arrows, active effects and all input remain outside this change |

The native ordered groups are backing, blueGlow, meter/hoops, glowRing, faces.
They share the original widget canvas; native field references and callbacks
stay alive. The new rail reuses the core's existing validated read/subscriptions
and exact controller. It never calls SetProgress on circleFill or writes a model.
Critical unknown values/predicate, disabled owner/controller/feed or shutdown
reveal the original backing/meter/face ancestors and hide the custom view.
Changing a captured gauge field or its parent retires only the extra gauge,
reveals its native groups and leaves the foreign parent alone until HUD recreation.
Repeated refresh creates no further gauge or subscription.

The176 Lua5.1 Source/mock controls cover real fraction endpoints/updates, zero
inventory, known/unknown readiness, preserved native progress callback writes,
refill/ready feedback and painter order, malformed-value fallback/recovery,
shape rejection, external reparenting, parent visibility, controller retirement
and shutdown alongside the existing equipment/map/team cases. These are mocked
contracts, not HKS/pixels or native alpha readback. Exact diagnostic0.7 remains
unchanged; content0.11 is informational and is identified by its Source/Lua hash.
One causal check covers the two actual0.9 value tuples: remaining0/fill0/ready-1
then remaining5/fill0/ready-1. With the exact known mock shape, both show the new
frame/empty track; the fill quad stays absent at0, with EMPTY then UNKNOWN text.
Readiness-1 does not veto the gauge or become READY. The actual0.9 trace did not
measure all nine child identities/order, so it does not prove shape acceptance
or new0.11 rendering in the game.

Source0.10 stays frozen and was not played by this lot. New original pixels must
verify that the extra shape is accepted, native charge circles actually give way
to the frame/linear rail, fill and native glows remain readable, selected card
identity stays readable, and status/equipment/ammo have no clipping or overlap.
No new Game/native/FF/asset/build/lease operation follows from this Source work.
Authentic textures, perk identity adaptation, all other full-HUD states and owner
acceptance remain separate open work; BO3 is inspiration, not a completion ceiling.

## Actual0.11 and selected-card identity Source0.12

The closed case `20261015-081313-329-9807e647` is recorded in
[server PR269](https://github.com/maxis0191/iw7-paris-server/pull/269), merge
aa8a18f94f829ec203c6cf5519e1d956f3abadb9. Root, Ops and UI independently viewed
three original1280x720 BMPs. The thin angular frame/empty rail, CARDS5 and clear
UNKNOWN below the deck are visible; the old backing/hoops of that gauge are not
visible in these three poses. Ammo12/48 to11/48 to12/47 and the visible essentials
remain readable. Native card/fan/triangle and perk art still make a hybrid HUD.
EMPTY0 remains trace-only; no nonzero fill, glow/readiness progression or exact
nine-child runtime identity/alpha readback follows from the frames or bind.
The UI's8968B/ADD82F1B5728460CFFAD3EE18D588813C377BF04DA9893B9E93846D575ACBFBC
review was passive; direct closure/PTY/fresh proof belongs to Ops and Root.

Source0.12 addresses the observed selected-card identity surface. At the same
retail pin2305708efff4227ba7cb14495ff2c31bcf6e53cf, `FateCardOnDeck` has exactly
three original children: cardBack, name, icon. Their model subscribers remain
alive and keep native nonnil-only updates. The localized name is used directly;
it is not looked up, localized again, uppercased or replaced by a family label.

| Native selected model | Proven authority and boundary |
| --- | --- |
| consumableDeckSelectName | Selected slot → actual controller/Coop zombiePlayerLoadout/zombie_consumables reference → localized CSV Name; negative slot gives empty string |
| consumableDeckSelectIcon | Same real selection → CSV Icon; negative slot gives nil, and native retains its last image until its own callbacks/visibility change it |
| consumableDeckSelectBacking | Same selection → CSV CardBacking; negative slot gives nil, not proof of a neutral or empty card |
| consumableDeckSelectRarity | Same selection → CSV CardRarity; separate from readiness or activation |

CSVUtils identifies the authority as `cp/loot/iw7_zombiefatefortune_loot_master.csv`,
not the similarly named `cp/cp_consumables.csv`. Name/Icon/CardBacking/CardRarity
are columns4/10/21/22. All62 pinned rows have25 columns and exactly five backing/
rarity pairs: zm_wc_fate_card_base with empty rarity, or zm_wc_fortune_card_base
with common/rare/legendary/epic. These are the entire new eligibility allowlist.
No item names/effects or BO3 equivalences are guessed; actual name/icon remain
the original widgets and images. Unknown future pairs retain native artwork.

The new face is an authored white-material dark surface/open frame with a clear
FATE/FORTUNE family heading and the exact nonempty rarity in a second row. Its
header avoids the union of native name/icon positions, including the child's
meterFull sequence. Original name/icon fonts, bounds, alpha, color, references,
subscriptions and sequences are not changed. Only the old cardBack rendering
has an owned same-canvas mask, with that original object/material callback still
alive for fallback. Exact three-child identities/order/parents and all four
typed models/pointers/controller are required before any reparenting. The new
painter order keeps the original background behind the actual name and icon.

The parent FateCardWidget still owns all19 OnDeck alpha writes,37 position writes,
26 alpha writes for each name/icon,16 name color writes, count/selection/refill/
Fire/arrows and input. Activation4 selects the original refill sequence;
dpadPressed1 selects cardCycleN; ready1 chooses meterFullN/FireOn outside refill;
ready0 chooses initialN/FireOff; remaining0 chooses noMoreCards. No new state
machine reimplements them. Triangle is a distinct animated sibling, not the
selected backing, and remains outside this lot with the0.11 gauge and glows.

In particular, readiness-1 alone does not say whether a native selection phase
has shown name/icon. Original initial/refill states intentionally hide them;
cycle/meterFull states can reveal them through native callbacks. The new surface
does not force that visibility. If valid selected values exist but native name/
icon are hidden, only the new backing's family/rarity presentation can show with
the native parent. No selected name/icon/backing/rarity values were measured in
actual0.11, so those count/fill/ready snapshots do not predict0.12 eligibility or
identity pixels. A future separately authorized capture must establish them.

Missing/invalid values or pairs reveal the original backing and hide the new
surface; legal values can recover. Controller/model-object/field/parent changes
retire only this surface until normal HUD recreation, without retargeting native
callbacks or moving a foreign-owned object back. Shutdown reveals the native
backing. Repeated root refresh adds no more nodes or subscriptions. An optional
`identity` marker emits only branch/family/rarity changes, at most32 transitions
plus one suppression notice per weakly held widget. It prints no actual name/icon,
uses diagnostic0.7 and is ignored by the existing essentials parser. Its local
widget_seq is no native render/root identity, alpha sample or pixel guarantee.

The197 Lua5.1 Source/mock controls include21 new causal checks for the five real
pairs, original identity updates and nonnil behavior, hidden/refill/cycle/end
phases, native child positions/colors, controller/model/parent retirement,
unknown recovery, malformed model/reader/pointer refusal, repeated refresh, shutdown and bounded
diagnostics. No coordinate-mirror assertions, bitmap, native ABI, Ops enum or
runtime CSV/player-data reader was added. New references stay outside Git:
CSVUtils42298B/707B2AF6E3C4E2B861729C2533F78AF69C608DF645F264FB528035B00FB8EB7B;
loot master13642B/CFC47923771129CB3A2FF26DE57F35227696BE682305A1E9EEFF64D6BE8EAE30.
The preserved OnDeck3569B/980CA8B0D290F6A84C3882A8080C6D0B1BB5AF48F0D77EF4C97B6EDA29A04DC6,
parent73245B/78885351291D84DE552A4E92D89DF26576303203307F922923CB6E8DA40DD8CC
and models112038B/16D6D198A19C4615023B55D78BF3F74DCE8C493FDFBE472A138450F38817FE44
provide the callback/model contract. No dump body or player nickname is committed.
All0.11/0.10/0.9 evidence stays frozen; no new Game or full-HUD acceptance follows.

## Actual0.12 and Source0.13 native action block

[Server PR270](https://github.com/maxis0191/iw7-paris-server/pull/270), merge
5235fd1e07744584924edd3bf6353a3c85ea2b7d, records the closed actual0.12 case.
Root, Ops and UI viewed three original BMPs: the selected surface and
FORTUNE/EPIC header, CARDS5 and UNKNOWN are visible; ammo remains12/48 to11/48
to12/47. The selected effect name/icon are not identified. The later known_pair
event implies four valid strings under pinned Source, not independent raw
name/icon or alpha readback. ready-1 does not establish a native animation phase.
There is no alpha correction or new card-selection/use scenario in Source0.13.
All0.12 files, capsule and evidence remain immutable.

The next finite block is the existing native local-action container. Its real
localized title and progress remain the information source. An owned dark
surface with a fine rim is added **inside the original Accent**, which already
precedes Header and ProgressBar in the original painter order. This supplies an
underlay without reparenting native fields, replacing their models or guessing
an insert/depth API. It stretches with that map's original accent canvas rather
than imposing a common fill shape. Native Accent image/blend/geometry and alpha
stay intact; original Show/Hide animations also control the underlay. Actual
blend, contrast, native accent residuals and readability still need Game evidence.

The complete five outer containers and the five additional DLC bodies were read
at pin2305708efff4227ba7cb14495ff2c31bcf6e53cf before extending the candidate.
The four DLC progress factories retain the same actual secureProgress
subscription and Mask/Fill structure as the base; their material names differ.
Attack's fill bounds also differ and remain unchanged. All four DLC outer
containers instantiate HeaderDLC1, whose single MessageText differs from the
base header's nested Background plus MessageText.

| Read DLC body | Bytes | SHA256 |
| --- | ---: | --- |
| ReviveBarHeaderDLC1 | 1108 | C6B184C68AAF9516787088932916C444F358A6A1FB0346C3338F372A165A8DD8 |
| ReviveProgressBarDLC1 | 1814 | 5C76B070BA04B9A3D0721A6193322CE8EA66521126A9691246654F8175E01C8C |
| ReviveProgressBarDLC2 | 1814 | 6EFEB5A1328625CAFEFA246B54B1977FF5AE49A76EFF16F39456FCCA79079F36 |
| ReviveProgressBarDLC3 | 1814 | A50762407325893722ED2679844BA402AA610FEFECBA07EF4E4C628E61ACB47D |
| ReviveProgressBarDLC4 | 1815 | EC970FFB808B031332B95A367DFEB5C2A325A754FB22100C80FBDD015210C176 |

These text bodies and their Git-blob/byte receipts remain outside Git. No bitmap,
dump body, new native ABI, diagnostic kind or gameplay publisher is added.

Before adding anything, the finite style function requires a known container
identity, exact native outer/header/progress child order and parents, original
SetHeader/SetProgress methods, and an empty native accent. Base and DLC schemas
are checked separately. An unknown/incomplete/foreign structure stays native
without invalidating the essential HUD bind and can recover before ownership is
established. Once installed, a field/parent/child/callback/container/controller
change retires only the added view; a foreign child/hook/parent is preserved.
Checks run during existing root refresh, not continuously. Shutdown removes only
our view under the captured accent; it never moves a native field or restores a
foreign hook. Existing Source0.5 wrapper placement/palette remains for an eligible
action; instantiated HUDs still need normal VM teardown for complete rollback.

Independent review rejected initial candidate7d11f78: its replaceable public
widget marker was incorrectly treated as the owner record, allowing a forged
record to hide/remove/close a foreign view. A causal executed against that exact
old candidate reproduces the violation. The correction keeps authority in a
captured local weak registry and compares marker identity before any retirement;
the marker and foreign record are never adopted or inspected as an owner. A live
owned view strongly retains its real record, so marker replacement plus GC cannot
discard ownership before refresh/shutdown. After retirement, a weak-key boolean
prevents silent readoption even if the real record is collected and the marker
was erased. These records do not strongly retain dead HUD trees. Object/nil/
incorrect-type replacements, forced GC and shutdown are covered separately;
the rejected candidate remains in Git history.

Original SetHeader retains localization, font, text measurement and header
sizing. Original SetProgress retains its actual clamped stencil geometry and
duration, original Fill/Mask images and callbacks. secureState/ui_securing and
secureProgress/ui_securing_progress remain untouched. Off0, Reviving3 and
Skeeball21 are native states; unknown nonzero states keep native behavior,
including an empty title. No duplicate title, target, percentage, countdown,
progress prediction, model write, subscription or timer is added. The separate
world-anchored ReviveBar and downed/self-revive controls are unchanged. Creators
already using this native action path can reuse this small presentation function;
it does not claim a new generic objective interface or a new gameplay capability.

222 Lua5.1 Source controls pass, including25 new causals: five distinct schemas,
native object/material/stencil/callback retention, true callback-driven
start/progress/cancel/Skeeball and unknown state, unchanged measured title and
duration, no extra subscriptions, controller isolation, malformed/late schemas,
foreign ownership/callback changes, retirement, repeated refresh and shutdown.
A separate local cross-check executes the12 pinned retail outer/header/progress
bodies across all five variants:45 assertions pass, including native callback
identity, material/mask geometry, no extra subscribers and Show/Hide endpoints.
UI nodes, text metrics, animation timing and the untouched nested header
background are mocked in that cross-check; it is not HKS or rendered gameplay.
Its2735B receipt SHA256 is
1C418BB2B0124B9644AD2EA08F2BC5AC184864E55B2C4341B6C5300885E5DB1F.

Next: exact-head Source review/CI/merge, then a separately reviewed caller and
Root Game decision for natural action progress/cancel/return. Real co-op revive,
normal-damage/downed acceptance, all five maps, split/safe area/localization,
full HUD and owner acceptance remain unqualified. No Game/native/FF/stock/lease
operation follows from this Source change.

## Source0.14 dark fan backs and restoration

The actual0.12 frames show pale lower fan strips alongside the native Triangle.
Source0.6 used `white` over the full192x352 inset for both fan images: the native
gray overlay at alpha0.6 consequently washed over the authored dark backing.
Source0.14 confines that same overlay object to an8x344 inset stripe. Its native
depth RGB/alpha remain untouched; the underlying dark surface and five thin
authored rim/rule rectangles stay within the same footprint. This is original
vector-style decoration using the existing white material, not retail BO3 art.
No image binding, guessed asset, copied identity or card effect is introduced.

The pinned `FateFanCard` body at2305708 has exactly two direct leaf children,
`fanCard` followed by `fanOverlay`, with static material names and source bounds
-11.5/244.5/0/512. Its parent `FateCardWidget` sets the depth tint/alpha and owns
all four cards' count-dependent alpha, rotation, scale and position sequences.
The new adapter requires those exact field/object/parent/child relationships
and leaf IDs. Unknown or additional shapes remain native without failing the
essential HUD bind; a late eligible shape can be retried before ownership.
Fresh factories and existing roots use the same checked path and local controller.

Each eligible fan keeps both original image objects directly under the native
fan parent, followed by one owned rim container. No original animation,
callback, model subscription, input, timer or parent transform is replaced.
The four-card stack, selected identity, Triangle, Fire, arrows, native charge
glows and active effects retain their existing behavior. The demon/core and
selected-card masking contracts are unchanged. This small lot does not resolve
the remaining Triangle silhouette or qualify the complete HUD.

A local weak-key/weak-value registry is cleanup authority; the replaceable
`__bo3FanBack` marker is only an identity check. The live owned rim container
holds the captured record independently of that marker, including across GC.
Controller, marker, native field, child order or parent changes retire the fan.
Shutdown also retires every live captured owner. Captured native leaves are
restored to the pinned materials/bounds only while still referenced by this
widget and parented to it; the backing returns to its default white tint, while
overlay RGB/alpha and parent pose remain native. A leaf adopted by a foreign
parent or replaced through a field is left alone. Captured empty rim rectangles
are disposed only under their captured container; foreign children, descendants
or an adopted container are retained. A retired fan cannot be recreated by
clearing its marker. Structural checks do not detect arbitrary foreign writes
to the same leaf's rendering properties. Normal VM teardown remains required
for the rest of the existing HUD layout; no full hot rollback is claimed.

Source validation passes241 Lua5.1 mock controls, including empty/selection
poses, depth changes, controller isolation, repeated refresh, late/unknown
schemas, marker forgery/nil/type replacement plus GC, foreign fields/parents/
descendants, retirement and shutdown. A separate local cross-check executes
the pinned fan and full parent sequence bodies:349 assertions compare native
versus adapted endpoints for counts5..0, initial/cycle/meterFull/noMoreCards,
Fire/arrows/Triangle, depth values and restoration. Nodes, timing and the other
nested widgets are mocked; these are not HKS, game, texture or pixel results.
The actual0.12 captures remain the observation baseline; no0.14 game was run.
The external953B cross-check receipt SHA256 is
024F07F53B817EE1CA4A62AC336E09132FAA3958CA436EE18CA1B15960B36084.

Next: exact-head private Source review/checks and merge, then a separate caller
adoption decision. The frozen0.13 DiscoveryOnly package is unchanged. Any0.14
HKS/pixel validation, co-op, other maps/resolutions and owner acceptance remain
unqualified; this change grants no runtime/stock/launch authority.

## Actual0.14 and Source0.15 fan readback probe

The original1280x720 pre-action BMP from case20261015-144108-402-ee24194a
is3686454B, SHA256
C51EF882DDF3514CFBA3492E4DD80B3F20190C8BF5095362F31F13773BB2CA2C.
Root, Ops and UI personally viewed it without cropping or retouching. The pale
strip below the large Triangle remains visible, with no evident8px difference
against actual0.13b original3F4401AFE515F924E4D06096E7D474E3768AB2399717ED0D4DAC66821C988E22.
FORTUNE/EPIC, CARDS5/UNKNOWN and12/48 are readable. No active action bar or
selected effect name/icon is qualified. The actual0.14 log contains the module
content0.14/diagnostic0.7 and `factory_applied key=FateFanCard`; the factory was
called. This does not establish that its exact shape was accepted or that the
leaf setters held. The before/after binding records are not rendered-fan proof.
This observation supersedes any expectation that Source0.14 already demonstrated
a visible correction. It does not justify another art or dimension adjustment.

A deterministic observability gap exists: `style_fan` returns its original
widget even when preflight refuses it or its protected shape reader errors.
The generic dispatcher emits `factory_applied` for that successful return.
It cannot distinguish skipped, applied or retired fan adaptation. In the pinned
MenuBuilder body914-920, BuildRegisteredType simply calls the registered
constructor and returns it. The pinned FateCardWidget sets fanOverlay RGB/alpha
and animates the four fan parents; it does not rewrite these leaves' image or
local bounds. Its initial sequence writes alpha0 to all four fan parents.
Actual ready-1 does not establish the current native sequence, alpha or the
identity of the pale pixels. Target refusal, later writes and visibility/layer
ownership remain hypotheses until the new observations exist.

Source0.15 adds observation only, preserving the0.14 art and all model/input
behavior. Optional `[BO3 HUD] fan` rows retain diagnostic0.7; the essential parser
does not consume them. They distinguish exact preflight reasons, successful
return from our initial writes, live owned refresh and retirement. Each row has
a module-local widget sequence and module instance tag. A deck checkpoint
reports the actual fanCard1..4 field relationship and last root sequence seen.
The native parent's cardAnimation is reported only for the exact17 known
initial/cycle/meterFull/noMoreCards names, otherwise unknown. These tags and
checkpoints do not prove native VM identity or join cases across module epochs.

The only native render-state getter used is existing `getLocalRect`, already
used by the pinned retail HUD/action code. Its four current values are read in
pcall for the parent and the captured backing/overlay leaves, with separate
known/missing/error/invalid-numeric status. Finite values are rounded to three
decimals; non-finite or oversized values stay unknown. Missing values never become zero or a
successful match. Numeric rectangles can be unsettled before layout and are
not transformed screen bounds, an applied-material readback or pixel evidence.
The probe does not force layout. Rendered alpha and image remain explicitly
unknown because no corresponding reader has been qualified.

Seven transparent instance wrappers observe later calls: setImage and
SetAnchorsAndPosition on each original leaf, overlay SetRGBFromInt/SetAlpha,
and parent SetAlpha. They call the captured original first, preserve every
argument and return including nil holes, and preserve original errors. Geometry
arguments, native depth/alpha call intent and a material-argument reference
comparison are distinct from actual geometry readback. Material reference
inequality is not proof of different pixels; an alpha call is not sampled
render alpha. Diagnostic failures cannot block the original callback.
The initial Source setter calls are recorded only after they returned, before
later native writes; this does not promote them to verified material state.

Probe hooks are retained by the existing captured fan owner, add no timers or
subscriptions, and retire before native restoration. Only still-installed
wrappers are restored; a foreign setter is preserved and the remaining probe
hooks stop at the next deck checkpoint. Unknown shapes install no wrappers.
Foreign marker/field/parent/descendant and GC protections from0.14 remain.
Records are weak-keyed without root/widget closures. At most16 widgets emit
up to32 changed rows each, plus one suppression row per widget and one global
widget-limit notice; identical rows are deduplicated per event. Later widgets
install no probe wrappers. The cap limits observation, not native execution.

Source controls pass261 Lua5.1 assertions, including actual-reader disagreement
with setter intent, missing/error/non-finite readers, nil-hole returns, original
errors, borrowed receivers, foreign setter preservation, deduplication,
suppression and restoration. The two pinned retail bodies pass358 endpoint
assertions, including real initial alpha calls and untouched sequence tables.
These APIs, timings and nested widgets are mocked; no0.15 HKS or pixels exist.
The external953B retail-body receipt SHA256 is
2133FEA8E6272CB6C3783A26800867C6BE7A2C8CE78EA09078AC1D72F486A7B8.
The existing Ops264 essential parser accepts16 actually printed mock rows,
including six optional fan rows, at diagnostic0.7 and refuses0.6. This confirms
compatibility only; ignored optional rows do not qualify a rendered fan.

Next: exact-head private Source review/checks/merge, followed by a separately
reviewed probe consumer and a distinct Root runtime decision. A future original
frame and same-case fan rows must identify the actual widget, shape branch,
initial writes, later calls and current rectangle status before any correction.
Missing/suppressed evidence leaves the cause unknown. No Game, power, charge,
navigation, FF, PE or native-build authority follows from this probe.

## Actual0.15 and Source0.16 publication contract

The closed actual0.15 stdout from case20261015-155056-423-0e4d5040 is11701B,
SHA256 DE6BB901C3C8DBB10CF6EA40811850B683CC1B49DED209F36A4E49D42791F9DF.
Its20 complete raw fan lines cover four module-local widget sequences and five
stages each: applied, overlay_rgb, overlay_alpha, parent_alpha and deck. Every
line contains only version/widget_seq/controller/stage/reason/pixels/instance.
No slot, root checkpoint, reader status, rectangle or setter argument is
published. The raw bytes contain no NUL; detailed core rows remain present in
the same file. This is a publication failure, not evidence of a missing getter,
zero geometry, current render alpha, widget/root identity or the visual cause.
The original3686454B pre-action BMP SHA256 is
D4923B1D303EFAACDB636368EB6499ACB01D64673FB9F0B1D0DA7B4E87A7F4BE.
Root, Ops and UI viewed it: the hybrid Triangle/pale strip remains, with no
visual correction expected from the0.15 observer alone.

The concrete Source defect is that an ordinary fan row can contain no sample
fields and no explicit failed-collection state. Source0.15 discovers keys using
pairs, a dynamically populated array, table.sort and ipairs. Source0.16 replaces
that discovery with a closed42-key order, direct lookup and numeric iteration.
Every non-suppressed row publishes all42 keys, with unknown for unavailable
values; sample_status distinguishes completed collection from its protected
failure path. Completed collection does not mean that a getter succeeded.
The field_count header outside the suffix is42 for those rows and0 only for
the existing suppression notices. The exact reason why the0.15 runtime omitted
the suffix remains unresolved; no HKS/ABI/global-iterator explanation is claimed.

The pinned upstream77e [print bridge](https://github.com/auroramod/iw7-mod/blob/77e6d4d24e918ee363b3feee3735c3b889dff7d7/src/client/component/ui_scripting.cpp#L294)
assembles tostring arguments and passes the buffer to console output. This
Source reference does not verify the current executable or exclude every
current transport behavior. The correction establishes a complete emitter
contract; another actual run must still confirm the resulting wire bytes.

The same unknown semantics, seven transparent setters, weak records, callbacks,
returns/errors and0.14 art/dimensions are preserved. Source0.16 adds no reader,
model write, timer, subscription, material, Native code or input. Diagnostic0.7
remains compatible: fan rows are optional and do not qualify essential binding,
native VM identity, rendered alpha/image or pixels.

An end-to-end Source test loads the authored module and captures its actual
print arguments in Python, without a formatter replica. Four cases cover normal
collection, collection failure, controlled empty key discovery, and their
combination. The immutable0.15 module under the controlled empty-discovery
counterexample really emits common-only rows; the new module under that same
condition emits its full matrix. This counterexample is not the runtime HKS
cause. Independent getter values also disagree with setter intent, preventing
a mirrored-intent test from passing. In failed collection, every unavailable
field is explicitly unknown and sample_status is failed.

Source controls pass341 assertions, including80 actual-emitter print checks.
Every ordinary row has50 unique keys including its eight header keys, and every
token is at most40 characters. The conservative derived bound is2598 ASCII
bytes including newline per fan row and1374342B per module at the unchanged529
row maximum. These are bounds derived from the schema and existing caps, not
new runtime cutoffs; suppression rows are shorter. The captured test maximum
is964B per row. No larger Lua module limit is introduced: this Source remains
within the Ops131072B Lua boundary; configuration remains65536B.
The external13713B causal receipt SHA256 is
B6B8E19AFAE59D9760A3A78741D3A7F29E167DE9EF34873C56C21F876A54970E.
The two pinned retail bodies also retain their358 endpoint assertions. The
current essential parser accepts16 actually printed mock rows at diagnostic0.7
and refuses0.6: five fan matrix rows and one zero-field suppression notice are
ignored optional rows, not binding or getter qualification.

Next: exact-head private Source review/checks/merge, then a separately reviewed
consumer and distinct Root runtime GO. Future raw fan rows must contain the
matrix before any getter, geometry, association, overwrite or visual cause can
be qualified. Preserve all0.15 and earlier artifacts. No new capsule or Game
follows from this publication correction.

## Source references and implemented essentials

The official Aurora source API and a pinned public decompilation were read:

- [Aurora ui_scripting source77e](https://github.com/auroramod/iw7-mod/blob/77e6d4d24e918ee363b3feee3735c3b889dff7d7/src/client/component/ui_scripting.cpp).
- [IW7 reference pin2305708](https://github.com/deshayu/iw7-dump/tree/2305708efff4227ba7cb14495ff2c31bcf6e53cf/ui/ingame/cp).

Selected reference bytes/blobs are retained under ignored external runtime.
Decompiled control flow and names remain reference evidence, not proof of a
current VM/runtime ABI. No decompiled body is copied into tracked implementation.

| Component | Actual IW7 source contract | Prototype behavior and mask |
| --- | --- | --- |
| Round | inGame.CP.zombies.waveNumber | New WaveNumber widget and red count; original round leaf replaced, parent boss/escape visibility retained |
| Ammo/reserve | currentWeapon.clipAmmoRightDisplay, clipAmmoLeftDisplay, stockAmmoDisplay; ammoInfoAlpha/ammoReserveAlpha | New weaponinfoZM, dual/melee display and authoritative alpha; original ammo leaf replaced |
| Weapon/PAP name | currentWeapon.displayNameMultiline | Actual localized name; no inferred PAP tier or RayGun name |
| Portrait/currency | Existing MainPlayerInfo PlayerIcon/PlayerCash subscriptions, CP.players.image/bigImage/currentPlayerCash | Original pair moved once to the hero; character/status/cash callbacks retained; cosmetic box/dollar sign detached; quest children retained |
| Team identity/currency/status/mic | PlayerCash CPPlayerInfo grid, filtered GetCPScoreboardRowData(row, target, true), complete scoreboard mic flags | Original three teammate rows refreshed by retail, actual name/currency/status; hero identity/mic refreshed after native RefreshRows |
| Perks | CP.zombies.perks.activePerks/activePerkBits; element data.icon | New CPPerkIcon, dynamic runtime image; original toggle-list/order/lifetime retained |
| Offhands | primaryPower/secondaryPower charge, icon, color and alpha models | Original ZomWeaponInfo children retained, not hidden by replacing the ammo leaf |
| Local action | CP.zombies.secureState/secureProgress, native SetHeader/SetProgress | Owned underlay inside native Accent on five checked schemas; actual title/fill/stencil/order/visibility retained |

Version0.1.1 requires an explicit non-melee classification before showing the
left akimbo count: dual must be true and melee must be false. The prior source
treated an unresolved melee value as non-melee. The pinned retail weaponinfoZM
flow requires explicit false; this source correction covers nil-to-known model
transitions without inferring ammoInfoAlpha semantics or changing engine data.
It remains separate from the frozen native903/source-cbd5 tuple assigned to the
first future HKS capsule; that capsule must not silently adopt this evolution.

The first appearance uses native rectangles and IW7 runtime images. BO3 retail
HUD/perk/weapon image names/pixels are currently unqualified. No ImageGen asset
is necessary for this functional slice. If a real gap survives asset inventory,
the proposed created adaptations are an alpha portrait border256x256, ammo
backing384x128 and round marker128x256 without photos/numbers/text. They must be
tagged created adaptations, saved in the owning project and never called retail.

## Complete coverage and selective masking contract

| State/information | Current preservation | Required future replacement/verification |
| --- | --- | --- |
| Four players, join/leave, score sort, mic/status | Source0.3 reuses the native three-row PlayerCash grid and refresh; original scoreboard/nameplates/talkers remain | Real cooperative/spectator/row-recycle and long-name verification; no player count fabricated |
| Downed/last stand/self revive | Source0.5 styles native timer/title while keeping end-time/visibility/token callbacks | Real downed countdown, current buttons and normal damage versus script-entered test |
| Revive progress/cancel/return | Source0.13 adds a checked Accent underlay to original ReviveBarContainer/DLC1..4, retaining title/mask/state/progress/visibility | Actual native action/revive/cancel/Skeeball/return flow, contrast and blend under scoped protection |
| Perk grant/loss/order/DC | Original activePerks/activePerkBits and image source | Grant/loss/respawn/DC and all image readiness; no color-only state |
| Reload, alt mode, akimbo, melee, zero/infinite ammo | Live ammo display/alpha; original AmmoWarning/UnlimitedAmmoIcon | Reload/alt/name/zero/infinite transitions and controller glyphs |
| Equipment/charges/crafted/Mule | Source0.5 arranges original quantity/icon/warning/crafted/Mule/infinite widgets | Real zero/positive charges, glyphs, warning colors, third-weapon/infinite state and overlap |
| Power-ups and activation/timer expiry | Source0.5 arranges original toggle-list; activation queue remains native | Actual icon/stack/cancel/Flash/expiry and queue concurrency; no static icon rows or invented timer |
| Fate/Fortune cards | Source0.3 separation confirmed solo; Source0.4 compacts the whole native deck with every child/state intact | New scaled card/fan/charge/active-list overlap, glyph readability, selection/input and activation feedback |
| Interaction prompts/prices | Hints/InteractiveObjectPopup/interactionNotification | Keep actual key/glyph, text/price/focus and priorities; never blank through a HUD parent |
| Hit markers/damage indicators | PlayerDamaged/HitMarker/HitMarkerIcon/CPDamageIndicator | Preserve aim, contrast and damage meaning |
| Quest/map-specific inventory | Source0.5 moves original MainPlayerInfo quest group away from cash; challenge/sticker/ghost/escape/boss/PAP timers remain native | Real five-map inventory/text/Rave/chi/element flow, no clipping or missing item |
| Round/intermission/boss/endgame splash | Wave parent/message queues/splash widgets remain | Native transition timing and overlap with vote/server UI |
| Spectator/death/respawn/menus/frontend | Original HUD visibility parents, spectator and popup flows | No stale callbacks/widgets, focus/glyph preservation and safe rollback |
| Resolution/safe area/split controllers | Stock HUD parent lifecycle and _1080p scale; actual controller index | 720/1080/1440/ultrawide, safe-area, split-screen and scaling with readable text |

Only declared replaced leaves/cosmetic nodes are removed. Critical prompts,
crosshair, revival and unknown/map-specific widgets remain visible through their
retail path until a real replacement is ready. Thus full replacement remains
false; an essential slice or preserved information does not close this matrix.
The accessibility skill informs readability, controller-equivalent instructions
and redundant state cues; no web ARIA/screen-reader/WCAG compliance is claimed.

## Light validation and future runtime capsule

`ops/Test-BO3HUDSource.ps1` uses official Lupa2.6 Windows CPython3.12 wheel,
SHA256 c735a1ce8ee60edb0fe71d665f1e6b7c55c6021f1d340eb8c865952c602cd36f,
1688529 bytes, from PyPI. It installs only a binary wheel under ignored runtime;
no compiler/build. The authored Lua runs in Lua5.1 with explicit mock UI/models.
158 source controls cover default-off/private opt-in/frontend/MP, controller1,
dynamic round/clip/name, dual/melee/alpha/perk transitions, missing model fallback,
quest preservation, duplicate-load, owned-hook restoration and a captured retired
dispatcher remaining inert after shutdown. Added readiness controls exercise
both unresolved melee/dual classification and their return to known akimbo
state. Additional controls construct the retail wrapper/leaf hierarchy before
module load, retain live round/ammo subscriptions and critical children, verify
post-CreateHud return values, root identity, transient failure/recovery, hook
replacement, exact profile refusal and absence of duplicate cosmetic nodes.
Version0.3 controls add one-parent portrait/cash ownership and retained currency
subscription, authored card-fan/ammo separation, nested perks, actual teammate
currency updates for unchanged identity, one/four/leave/spectator mock states,
unknown mic flags, unchanged row callbacks and native refresh return values.
After draining all480 startup callbacks, a stock team refresh still updates the
hero name/mic with no queued work. Shutdown restores owned refreshes, preserves
an external replacement and makes a captured retired wrapper inert. These are
mock source causals, not real cooperative or visual acceptance.
The six0.8 controls add content/contract separation across actual emitted
markers, absent boss object and absent boss pointer with paired non-DLC4 versus
DLC4 outcomes, an invalid boolean-ready value retained as false in the trace,
and silent same-branch fill updates followed by the33-record transition cap.
They do not identify which branch occurred in the frozen0.7 HKS case.
Six0.9 causals add fresh construction with ready-1/count0, positive count with
local UNKNOWN, refresh20 and upper-bound30, recovery to0/1, unexpected typed or
out-of-domain values, and remaining/fill/DLC4 boss refusals despite legal-1.
They retain raw diagnostic values and original meter/callback objects. These are
mock Source causals; they do not turn an UNKNOWN label into real READY evidence.
Version0.4 adds native readiness/fire/arrow updates through successive layout
polls with unchanged parent alpha, callback identity, selected-card image and
child count. The separate active-card list keeps its native image and scale.
The overflow geometry control includes the deck transform around its center.
Source0.5 controls update independent offhand charge/image/color/visibility,
crafted glyph text, Mule/infinite alpha, late/fresh/expired/removed power-ups and
native activation messages. An incomplete power-up constructor is closed before
the native fallback is called; a subsequent healthy factory can recover. Revive3/Skeeball21/off0 transitions retain native
SetHeader/SetProgress identity and the progress mask through each poll. A positive
downed end time and later cancellation retain the native countdown/parent state.
Self-revive token messages and full-width progress remain native. Five mocked
root/player aliases retain fuse/inventory image/alpha, Rave fill and DLC3 element
text after the inventory group moves; these are Source-only callbacks, not real
damage/revive/controller/cooperative/map or rendered layout evidence.
Source0.6 adds four focused fan controls: original image-object identity,
unchanged native parent alpha/rotation and overlay depth/alpha after repeated
polls, no duplicate rim nodes, a fresh hidden factory remaining hidden, and
retained selected-card/fire/arrow state. These are mocked Source controls;
actual card footprint, depth, all-count animation and contrast need new original
frames when Root authorizes a suitable larger case.
Twelve Source0.7 controls cover the real-count/ready/charge/empty/refill readouts,
unchanged native meter callback/object/parent, retained face ordering, known boss
presentation and its still-updated native image, unknown boss/predicate/value
fallback, unchanged parent alpha, idempotent view creation, controller-identity
fallback and shutdown native visibility. These explicit mocks exercise Source
ownership and feeds only, not actual HKS model types or rendered state acceptance.
Root review of candidate3706 found that the failure cache survived a successful
recovery, suppressing a recurrence of the same fault and leaving stale external
bind evidence. Success now resets that failure key. The same-root/sequence
failure-recovery-same-failure control requires two emitted failure markers and
invalidation of the earlier success; the initial candidate remains in history.
Architecture review then found the reserve text's retail NoStockAmmo warning
color was overwritten on every style poll. That color now stays retail-owned;
numeric zero/positive-reserve callbacks followed by each next poll retain their
retail warning/normal colors. The new late-runtime fixture initially omitted
the numeric stock model, failed setup, and was corrected before qualification.
Peer review caught the complementary fresh-factory path: its custom reserve
count had no numeric warning subscription. It now follows the pinned retail
colors, SWATCHES.HUD.warning at zero and RGB12566463 at positive reserve, through
the real numeric stock model. Fresh construction plus zero/positive updates
and subsequent root polls preserve those exact colors in source controls.
This is not HKS,
render or gameplay evidence. An early test setup artificially cleared the module
global without destroying old scheduled callbacks; it was corrected to test the
actual same-VM duplicate-load guard rather than claim a fresh VM.

Future capsule must pin this native source commit/raw Lua digest and recipient
profile, reuse the base client/retained dedicated, reserve the complete Runtime
group before payload/native reads and take full profile/shadow/config snapshots.
Private password/LAN, actual engine Godmode/BOUND=1, inactivity0, sv_cheats0 and
safety age<=250ms gate every real input/capture. Keep Full graphics and authentic
frames at spawn, ammo/reload/weapon/perk changes, transitions, down/revive and
every map. Root grants each serialized Game case after the current CPP holder
closes. Stop only exact owned identities, restore/profile/Main-bank audit, obtain
the true PTY exit and then record pixels/limits separately. No Game occurred in
this source tranche; CPP/FF/GSC/extraction and Main deployment were not run.

# Private base-client activation

`New-IW7BaseClientPlan -BO3HUDPrivate` is an explicit, default-off disk-HUD
startup option. Its typed boolean adds exactly
`+set bo3_zombies_hud_enable 1 +set bo3_zombies_hud_private 1`; ordinary and
legacy plans keep their existing arguments. Original-rig console plans are
exclusive. The option does not install Lua, launch a client, select a Lua
revision, reload HKS, or qualify pixels. The server-owned profile transaction
must install the reviewed Lua before launch and restore it after exact owned
client/dedicated closure. Client `+exec` is not activation evidence because
retail profile loading can retain owner dvars.
