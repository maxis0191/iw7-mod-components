# IW7-Mod components

The private native side of the IW7 products. It holds the engine and client components that are added to the
IW7-Mod source at build time (owner-only console access, cooperative cutscene skipping, test privacy and safety
hooks, the diagnostics and recorders), the machine-wide scheduler that admits live sessions and builds, the tools
that answer questions about the engine (engine map, memory watch, performance recorder, freeze reporter, crash
reader, network measurement, live world editor), the supervised debugger, and the server-relayed voice chat patch
with its certification harness. Voice has not been tested in game and is not accepted.

Server gameplay rules live in iw7-paris-server, asset serializers in x64-zt-extensions and creator tooling in
iw7-creator-sdk. This repository owns exactly the paths listed in `product.json` under `exports`; the other
products take some of them by exact path through their own dependency lists.

## Where to look

- [docs/INDEX.md](docs/INDEX.md): which tool answers which question, how to run and build, which paths other
  products take, and which documents are history.
- [AGENTS.md](AGENTS.md): the rules for agents working here.
- The server repository's `docs/DEVKIT.md` and `docs/TOOLS-INDEX.md`: every tool of every product.

## Run the local judge

The judge of a commit is the local check run on that exact commit. The hosted workflow in `.github/` starts only
by hand and is not the judge.

```powershell
./bootstrap.ps1 -Output runtime/<short>
./checks.ps1 -Workspace runtime/<short>
./checks.ps1 -Workspace runtime/<short> -Only <check id>   # re-run one check after a fix
```

Prerequisites: Git (with `--attr-source` support), PowerShell 7.4 or later and Python 3.12. `bootstrap.ps1` needs
the GitHub CLI signed in with read access to this repository, to download the dependency archive once (or pass
`-DependencyArchive <file>`). The three checks that compile (`cutscene_test`, `owner_cheats_test`,
`native_unit_tests`) need the Visual Studio 2022 C++ tools and take the machine's build slot; they wait up to
seven minutes for it. Checks that need a
tool absent from the working machine (a Java 21 runtime; numpy and a speech voice; capstone and an unpacked
retail executable; the Python environment that `ops/Install-ReTools.ps1` makes from existing Ghidra and Java roots)
are listed in `checks.json` under `retained_checks` with the reason, and the run prints one `RETAINED` line for
each: they were not run, they did not pass.

`bootstrap.ps1` refuses uncommitted changes, and composes a fresh source workspace from this commit plus the
files named in `dependencies`, taken from the archive pinned by SHA-256 in `dependency-package.json`. The archive
holds selected text sources only, never tools, game data or binaries; a missing archive fails, no other version
is chosen. The checks do not install a game, copy game assets, start a game process, deploy or publish anything.

## Editing and source workspaces

- Edit the canonical tracked file here, never a generated workspace under `runtime/`.
- Every tracked file must be declared in `product.json` `exports`; `ops/check_boundaries.py`, the first step of
  `checks.ps1`, refuses the rest.
- The relative layout is a contract: other products and hash-sensitive tools name these paths. See "Paths other
  products take" in the index before renaming anything.
- A source workspace records each owner, commit, Git blob and byte hash. It does not qualify a native build and
  never inherits an older runtime receipt. Existing packages, dependency archives and receipts are immutable:
  a correction is a new package and a reviewed pin, never a change in place.
- `ops/source_workspace.py` limits each file to 1 MiB and a composition to 32 MiB, with one closed, exact
  exception for a table owned by x64-zt-extensions (path, blob and byte hash are fixed in that file). It is not
  a configurable size exception.
- To run an operation that needs another product's files, run it from a generated workspace or with
  `bootstrap.ps1 -Entry ops/<entry>.ps1 -Arguments @(...)`. Entry points keep their own input, identity,
  resource and authorization gates.

## How other products take these files

A consumer names a commit of this repository and a list of paths in its own `product.json`, then regenerates its
source inputs. Today the three consumers pin the branch `pin/server-447c1ad-shareable` (`9a3d30b`), not `main`;
that branch must never be deleted or rewritten. Details and counts are in [docs/INDEX.md](docs/INDEX.md).
To roll an integration back, restore the earlier pin in a new reviewed commit and regenerate; this never
restores or deploys game data, banks or binaries.

## History and evidence

Dated documents and frozen plans keep their original bytes and claims; a failed result stays recorded as
failed. A moved or rebuilt source needs a new plan and a new qualification. Older rules and the earlier README
are in `docs/archive/`; `migration/` maps the original server paths and commits to this history (authors and
commit messages were preserved by the extraction).

## Licensing

Preserve upstream notices and per-file provenance. No blanket license is granted
to all private adaptations by this extraction. Public distribution requires its
own license/privacy review and owner decision. Commercial game assets, dumps,
installed SDKs, PDBs, executables, credentials and player data are excluded.

This repository is private. Nothing private goes into a public fork, and nothing is sent to the public game-client
project (no issue, pull request or message) without the owner. Admin chat commands were cancelled by the owner
and are not to be reintroduced.
