# BO3-style Zombies HUD adapted to IW7 — source prototype

This client module is an authored IW7 LUI implementation. It is not a retail BO3
HUD import, a screenshot overlay or a complete qualified replacement yet.
The requested destination is a complete HUD adapted to IW7 characters, perks,
weapons, quests and states. Version0.4.0 follows the confirmed solo0.3 layout
with a smaller native card deck; the actual-player team layout remains Source-tested;
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

## Bounded binding diagnostics

Every module initialization emits `module version=0.4.0 instance=... initialized=1`.
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
  completed style calls, never pixels; every marker says `pixels=unverified`.
- `binding_failure` / `factory_fallback`: bounded reason and `retry=1`; transient
  missing leaves may recover. A binding failure clears prior bind evidence and
  recovery emits a fresh bind. Require the latest valid CP gate and concordant
  root/bind before capture; do not aggregate an older VM/root's markers.

Markers emit only on state changes; startup polling remains bounded. No player
names, balances, GUIDs or credentials are emitted by these diagnostics.
The grammar is unchanged from0.2.0. The current server-owned caller allowlist
supports0.2.0/0.3.0, with default0.2.0. It must reject this new0.4.0 tuple until a
separate reviewed Ops extension explicitly permits it. V3 and V4 remain frozen;
this Source follow-up authorizes no immediate capsule or Game replay.

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
| Downed/last stand/self revive | LastStandTimer, afterlifeSelfReviveProgress | Styled timer and current buttons; distinguish normal damage from script-entered test |
| Revive progress/cancel/return | ReviveBarContainer/DLC1..4 and real retail models | Keep actual target/use/cancel flow; P2 test under scoped protection |
| Perk grant/loss/order/DC | Original activePerks/activePerkBits and image source | Grant/loss/respawn/DC and all image readiness; no color-only state |
| Reload, alt mode, akimbo, melee, zero/infinite ammo | Live ammo display/alpha; original AmmoWarning/UnlimitedAmmoIcon | Reload/alt/name/zero/infinite transitions and controller glyphs |
| Equipment/charges/crafted/Mule | Original quantity/icon/alpha/CraftedWeapon/Mule widgets | BO3 arrangement without dropping offhand or third-weapon state |
| Power-ups and activation/timer expiry | ZomPowerupWidget/ZomPowerupActive/message queue | Actual duration/icon/stack/cancel transitions, not static icon rows |
| Fate/Fortune cards | Source0.3 separation confirmed solo; Source0.4 compacts the whole native deck with every child/state intact | New scaled card/fan/charge/active-list overlap, glyph readability, selection/input and activation feedback |
| Interaction prompts/prices | Hints/InteractiveObjectPopup/interactionNotification | Keep actual key/glyph, text/price/focus and priorities; never blank through a HUD parent |
| Hit markers/damage indicators | PlayerDamaged/HitMarker/HitMarkerIcon/CPDamageIndicator | Preserve aim, contrast and damage meaning |
| Quest/map-specific inventory | MainPlayerInfo inventory/quest children, challenge/sticker/ghost/escape/boss/PAP timers | Map-specific adaptive layouts across all five maps with no missing item |
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
97 source controls cover default-off/private opt-in/frontend/MP, controller1,
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
Version0.4 adds native readiness/fire/arrow updates through successive layout
polls with unchanged parent alpha, callback identity, selected-card image and
child count. The separate active-card list keeps its native image and scale.
The overflow geometry control includes the deck transform around its center.
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
