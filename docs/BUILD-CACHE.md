# Build cache: one folder for every worktree and every agent

Status 2026-11-18. Measured on the machine that builds the lab clients (13th gen i5, 10 cores, 32 GB), with other
agents building and playing at the same time.

## Why

Between 13 and 18 November, 96 lab clients (`runtime/el-*`) were built in 33 different worktrees: 96 different
commits, 96 different executables, 8.2 GB, about 3.4 hours of build time. Every fresh worktree built everything:
it cloned the pinned iw7-mod and its 17 submodules into its own native tree (2 GB each, 18 such trees on the
disk), downloaded the dependency archive again, compiled every dependency one file at a time, compiled and ran
the twenty native unit tests one after the other, then linked the whole program with link-time code generation.

## What it is

One folder, `C:\IW7-Cache` (override: `$env:IW7_BUILD_CACHE`; size cap of the packages: `$env:IW7_BUILD_CACHE_GB`,
default 40). Code: `ops/build/Build-Cache.Core.ps1`. Nothing in it is a source of truth: delete the folder and
every build still works, only slower.

| Folder | Holds | Key |
|---|---|---|
| `packages/<key>/` | a finished lab client: `iw7-paris-voice.exe`, `iw7-mod.pdb`, the build manifest | SHA-256 of every file of the prepared workspace that can change the executable (`src/`, the build and overlay scripts, `client-profiles.json`, `product.json`; not docs, tests or creator tools), the build switches, the pinned upstream, the Visual Studio toolset |
| `tests-pass/<key>` | "this unit test passed" | the test's own source, every header it can include, its compiler line, the toolset |
| `native-trees/<pin>-1/` | the native build tree (pinned iw7-mod, submodules, objects, libraries) | the pin; one tree per pin, taken in turn through a lock file |
| `source-dependencies/<sha>/` | the pinned dependency archive of `bootstrap.ps1` | its SHA-256 |

## What a build does now

`ops/Build-Voice.ps1` (called by `Get-LabClient.ps1` and `Invoke-EngineLab.ps1` of the server repository, never by hand):

1. Computes the package key from the prepared workspace. A package with that key exists: it is restored into
   `runtime/voice-package` and `runtime/voice-symbols/<sha>` by hard links, no tree, no scheduler reservation, no
   compiler. The manifest records `CacheKey`, `CacheBuiltForProjectCommit` and `CacheRestoredForProjectCommit`.
2. Otherwise takes the native tree of the pin (cloned only the first time on a machine), applies the overlays,
   runs only the unit tests whose own inputs changed, gives every source file whose bytes are what the last build
   compiled its old file time back (so a new workspace does not make MSBuild compile every overlay again), runs
   MSBuild in parallel (`/m:4`, `CL_MPCount` = half the logical processors, at most 8), stores the package.
3. Prints `Step ...` lines with the seconds of each part and `Build total`.

`-NoCache` ignores the cache (a diagnostic run), `-Serial` is the old one-file-at-a-time compile, `-NativeRoot <path>`
uses your own tree instead of the shared one. Opt-in voice images, `-TestsOnly` and `-Sanitizers` never use the
package cache.

## Measured, 18 Nov 2026

Same machine, other agents running; "work" is the build without the time spent waiting for the machine's build
reservation (the waits were 2 to 17 minutes and are not the build's doing).

| Job | Before | After |
|---|---|---|
| (a) fresh worktree, a commit nobody built, tree and cache empty / warm | 674 s wall, about 570 s of work: prepare 29, clone of iw7-mod and 17 submodules about 190, unit tests about 118, overlays and premake about 42, MSBuild 125 | 58 s of work: prepare 16, unit tests 38 (the first run with the per-test cache), overlays, MSBuild 3.5 (nothing to compile), package |
| (b) the same commit again, in another worktree | the same 570 s of work | **18 s**: prepare 16.6, restore 0.3 (hard links; no tree, no compiler, no reservation) |
| (c) one line in one component | see below | see below |

The median of the 96 builds of the last five days was 117 s from `Invoke-EngineLab` (p10 71 s); most of that was
queue time and the serial test compile.

## Cleanup

```powershell
pwsh ops/build/Invoke-BuildCleanup.ps1                          # report only
pwsh ops/build/Invoke-BuildCleanup.ps1 -Apply -IncludeOwnNativeTrees
```

Removes `runtime/el-*` folders older than 24 hours that are not among the newest three of their worktree, and
(with `-IncludeOwnNativeTrees`) per-worker native trees idle for 48 hours. It never removes a folder that a
running process names on its command line or that holds a scheduler lease, nor one with a junction or link in it.
Hard links into the cache are safe to delete. It also trims the package cache to its cap, least recently used first.

## Limits

- A native tree is never copied: MSBuild's tracking logs hold absolute paths, so a copy at another path compiles
  everything again (measured while building this).
- The link of the client uses link-time code generation (`/GL`, `/LTCG` in the pinned `premake5.lua`) and is one
  serial step; it is the floor of every build that changes any native source.
- Builds still wait for the machine's build reservation (`Resource-Scheduler.ps1`); the waiting time is reported
  as `slot_wait` by `Invoke-EngineLab.ps1`, apart from the work.
