# Existing community client: native-first capacity investigation

Owner direction, 20 October 2026: first use the existing Aurora/CB download and
content interfaces. Private project PRs are authorized; an official upstream
release must not be assumed available. Keep the automatic-client prototype a
fallback until these paths have been assessed. Do not substitute initial
execution of our own EXE for an unchanged community client joining a server.

## Verified source paths

The audit reads Git blobs, not the modified files in retained build checkouts:

| Client source | Exact revision | Relevant behavior |
| --- | --- | --- |
| Aurora | 37abcb260408ce7cdef0dde831bbfcad594510e3 | Mod FastDL, usermap FastDL, embedded Lua entrypoints |
| CB | d9c5dea1092b5ac493d2346043b26b2e2322d09c | Mod FastDL, broader Lua file IO; no embedded-zone Lua loader in this pin |
| Retained merged base | a99c04937513530648573fd4ca2a05321a90b4a5 | Aurora content features plus CB compatibility and reviewed loading fix |

`party.cpp` allows `mods/<id>/mod.ff`, with optional `mod.sabl`/`mod.sabs`.
It requires a nonempty `mod_hash`, validates the mod path, and compares file
hashes. `download.cpp` retrieves the selected content using `sv_wwwBaseUrl`,
verifies it, writes it to that content path, and reconnects. Switching to a
standard server clears `fs_game` and reloads content with `vid_restart`.

Aurora and the merged base additionally allow usermap `.ff`, `_load.ff`,
`_art.ff`, `.arena`, `.pak`, `.sabl`, `.sabs` and localized `.ff` files.
The earlier statement that FastDL cannot deliver any PAK was too broad: it can
deliver a usermap PAK. That file is opened as game content; it is not a native
plugin registration mechanism. A mod cannot add extensions to these tables.

Embedded `ui_scripts/<folder>/__init__.lua` assets are loaded by Aurora's
`load_zone_scripts`; GSC is handled by the existing script VM. Lua IO differs
between pins: CB exposes writing/moving/removing files while Aurora replaces
the IO table with read-oriented bindings. Neither inspected registration adds
a capacity patch, character-table resize or agent-codec interface. GSC
`executecommand` invokes the engine command buffer. `loadzone` calls the asset
database; `listassetpool` reports assets. The C++ asset-pool reallocations in
`fastfiles.cpp` concern asset types and are not a script-callable resize of
live agent/character records.

Do not infer that file writing supplies a supported native extension API, or
attempt DLL search-order tricks, memory corruption, shell execution or renaming
an EXE to a content extension. Those do not establish normal community-client
compatibility. This investigation inventories supported source interfaces; it
does not claim an exhaustive proof about every retail builtin.

The updater has publisher-selected origins. A server's `sv_wwwBaseUrl` selects
content downloads and does not redirect the trusted executable update channel.
Publishing a package on our own HTTP host cannot replace that missing release.

## Why downloading assets does not install the current capacity implementation

The qualified implementation changes native agent pools, character tables,
corpse partitions and both entity-state and independent agent-state codecs.
It installs the guarded patches before world allocation. With 18 reserved
player identities and 64 agent places, character identities reach81 and require
7 bits. The original explicit agent record has6 bits; a sparse identity64 can
alias0. Merely raising the GSC population, setting an otherwise unknown dvar,
shipping `mod.ff`, reloading a zone or changing server advertisement does not
apply those client patches. Removing the peer guard would expose incompatible
clients; it would not enlarge their tables or change their decoder.

This does not prove every alternative engine architecture impossible. Using
generic script models for additional bodies, or translating extra server agents
into noncharacter network entities, would be a different AI/animation/damage/
replication implementation. No retained result establishes retail-equivalent
behavior, quest integration or performance for48 such enemies. It is not a
qualified replacement for48 independent ordinary native zombies plus specials.
The smaller reviewed client capability is the selected fallback.

## Reproducible source/protocol observation

```powershell
python -B ops/Audit-ExistingClient.py --upstream-root <existing-native-checkout> --port 27016 --output <fresh-local-report.json>
```

This light audit reads the three pinned source revisions and can issue one
nonce-checked loopback `getinfo`. It never launches IW7, authenticates a player,
downloads or executes native code, sends RCON, or changes the server. It reports
source hashes, exact download lists, Lua entrypoint/IO differences and selected
nonidentifying server fields. A Source/protocol result must not be described as
a real fresh-player gameplay test.

The observed Main response on20 October2026 advertises `64-v2`, retail
`cp_zmb`, empty `fs_game` and empty `sv_wwwBaseUrl`; it has no `mod_hash` or
`usermap_hash`. Thus the existing FastDL path currently offers no feature
package to an ordinary client. Adding a valid downloadable mod would solve
asset delivery, while the native capacity capability would still be required.

## Selected delivery and remaining qualification

Retain existing FastDL for content. Include the reviewed capacity capability
in the community executable, then negotiate the known layout and restart before
allocation when changing between expanded and ordinary servers. Keep expanded
settings in one removable directory. This avoids a general downloaded-native-
plugin loader and needs no new retail assets for capacity itself.

The [automatic profile candidate](AUTOMATIC-CAPACITY-PROFILES.md) implements that
fallback in private PR98. Its one-file onboarding is an optional independent
distribution route; it still requires one initial execution by a player. A
player who only uses the unchanged official executable needs a publisher release
containing the capability. The current publisher updater can distribute that
release once its maintainers actually accept and publish it.

The account-wide build reservation remains owned by another live retained build
host. No native compiler or game was started by this investigation. A real
unchanged-client/private-FastDL observation and the fallback's compiled fresh-
cache24 ->64-v2 ->24 round trip remain unexecuted. Preserve the existing lease
and Main. No official PR, deployment, gameplay PASS or zero-lag guarantee follows
from this source audit.

The independent light managed Source test does compile the C# preparation code;
it is separate from the refused native build. Its actual PrepareData method
passes cold47/warm0/corruption-repair1 downloads with exact publisher bytes and
preserved quarantine. The native client and full onboarding entrypoint are not
executed. The Framework compiler path defect found by this test is corrected in
the package recipe. The data-only test is reproducible with
`tests/ops/auto_client_managed_test.ps1 -DownloadRoot <new-data-only-directory>`;
omitting DownloadRoot runs its offline managed compilation/manifest check.
The owner has explicitly authorized contacting the retaining orchestrator for
normal closure or controlled abandonment of its build. That GO has been sent;
this task still must not steal or delete its reservation.
