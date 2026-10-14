# BO3-style Zombies HUD adapted to IW7 — source prototype

This client module is an authored IW7 LUI implementation. It is not a retail BO3
HUD import, a screenshot overlay or a complete qualified replacement yet.
The requested destination is a complete HUD adapted to IW7 characters, perks,
weapons, quests and states. Version0.1.1 implements the first essential slice;
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

Two client-config strings must both be1: `bo3_zombies_hud_enable` and
`bo3_zombies_hud_private`. Defaults are off. The active scene must be nonfrontend
with ui_gametype zombie. A scoped constructor dispatcher catches lazy-loaded
retail factories; unrelated constructors and stock CPHUD/ZMHUD classes are left
intact. Shutdown restores the dispatcher only if it is still our function.
Existing instantiated widgets require normal HUD/VM teardown; no hot-reload
restoration claim. Close the owned client before file/profile rollback.

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
| Portrait/score | Existing MainPlayerInfo PlayerIcon/PlayerCash subscriptions, CP.players.image/bigImage/currentPlayerCash | Original character/status callbacks retained, portrait/cash restyled; cosmetic box/dollar sign detached; quest children retained |
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
| Four players, join/leave, score sort, mic/status | Original PlayerCash/scoreboard/nameplates/talkers | BO3 team stack with actual row identity/status; no player count fabricated |
| Downed/last stand/self revive | LastStandTimer, afterlifeSelfReviveProgress | Styled timer and current buttons; distinguish normal damage from script-entered test |
| Revive progress/cancel/return | ReviveBarContainer/DLC1..4 and real retail models | Keep actual target/use/cancel flow; P2 test under scoped protection |
| Perk grant/loss/order/DC | Original activePerks/activePerkBits and image source | Grant/loss/respawn/DC and all image readiness; no color-only state |
| Reload, alt mode, akimbo, melee, zero/infinite ammo | Live ammo display/alpha; original AmmoWarning/UnlimitedAmmoIcon | Reload/alt/name/zero/infinite transitions and controller glyphs |
| Equipment/charges/crafted/Mule | Original quantity/icon/alpha/CraftedWeapon/Mule widgets | BO3 arrangement without dropping offhand or third-weapon state |
| Power-ups and activation/timer expiry | ZomPowerupWidget/ZomPowerupActive/message queue | Actual duration/icon/stack/cancel transitions, not static icon rows |
| Fate/Fortune cards | HudBottomRight children/cards/selection remain | BO3-style layout retaining deck, charge, selection/input and activation feedback |
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
32 source controls cover default-off/private opt-in/frontend/MP, controller1,
dynamic round/clip/name, dual/melee/alpha/perk transitions, missing model fallback,
quest preservation, duplicate-load, owned-hook restoration and a captured retired
dispatcher remaining inert after shutdown. Added readiness controls exercise
both unresolved melee/dual classification and their return to known akimbo
state. This is not HKS,
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
