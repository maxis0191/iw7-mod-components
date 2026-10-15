# IW7-Mod components

Private engine/client components, voice protocol, native diagnostics, scoped test hooks and shared process/resource helpers. Server gameplay rules and asset serializers have other owners.

This repository is private. It complements the public owner forks; it does not
publish private project code into them. See `product.json` for exact source
revisions and explicit file dependencies. Source extraction preserved authors
and commit messages; `migration/import.json` and `migration/commit-map.txt` map
the original server paths/commits to this history.

## Editing and source preparation

Edit the canonical tracked file here. Do not edit generated source workspaces.
The existing relative source layout is an explicit compatibility contract used
by hash-sensitive tools. Dependencies contribute only their listed files to a
fresh, bounded source package; they are not vendored into this repository.
The composition receipt records every owner, commit, Git blob and checkout-byte
hash. It does not qualify a native build or inherit an older runtime receipt.

Run the pinned IW7-Mod `ops/source_workspace.py` with `--project`, exact
`--revision`, one `--source PRODUCT=CHECKOUT` per dependency, and a fresh `--output`.
Each source checkout must match the manifest revision and have clean tracked
files. Paths with spaces are supported. Missing, different, dirty, redirected,
oversized, binary and overlapping sources are refused before output creation.
Then run `checks.ps1 -Workspace <output>` from this canonical checkout.

Source export requires Git supporting `--attr-source=<tree-ish>`. Both filtered
export and checkout-byte validation read versioned attributes from each owner's
exact pinned commit, including sparse checkouts without a physical
`.gitattributes`. Declared LF/CRLF/filter semantics remain in force; this does not
export raw blobs or force all files to one line ending. Git blob identity and
the exported-byte SHA remain separate receipt fields. Existing Source packages,
dependency archives and native writer receipts are immutable; corrections use
fresh packages and reviewed dependency pins, never retroactive normalization.

The command does not install a game, copy retail assets, build native code,
launch a process fixture, deploy, publish, or change Main. Build/run entrypoints
inside the package retain their own input, identity, resource and authorization
gates. Feature experiments remain paused until the owner's explicit GO.

## Evidence and rollback

Historical documents and pinned plans retain their original bytes and claims.
Use the recorded original checkout/commit for a frozen experiment. A moved or
rebuilt source needs a new plan and qualification. Failed results remain failed.
To roll back an integration, restore its earlier dependency revision in a new
reviewed commit, generate a fresh source package, and rerun the relevant tests.
This never restores or deploys game data, banks or binaries automatically.

## Licensing

Preserve upstream notices and per-file provenance. No blanket license is granted
to all private adaptations by this extraction. Public distribution requires its
own license/privacy review and owner decision. Commercial game assets, dumps,
installed SDKs, PDBs, executables, credentials and player data are excluded.

## Reproduce the source checks

Prerequisites: Git, authenticated GitHub CLI with read access to this private
repository, PowerShell 7.4+, Python 3.12 and Node.js 22. Native source checks also
use Java 21; pure native compilation requires the existing VS2022 C++ toolchain.
Asset image tests use the hash-pinned Pillow requirement in ops/doom-textures.

```powershell
./bootstrap.ps1 -Output "$PWD/runtime/source inputs"
./checks.ps1 -Workspace "$PWD/runtime/source inputs"
```

Bootstrap downloads only the immutable source dependency archive named in
`dependency-package.json` from this repository's private release. Its SHA-256,
length, members, owners and commits are checked. It needs no cross-repository
CI secret. Offline use: supply `-DependencyArchive <downloaded dependencies.zip>`.
The archive contains selected text sources, never tools, game data or binaries.
A missing archive fails clearly; no fallback version is selected.

Run an authorized operation from the generated package, or use
`bootstrap.ps1 -Entry ops/<entry>.ps1 -Arguments @(...)`. Canonical repositories
are editing locations; operations requiring another product must use prepared
inputs. Older commands in dated documents refer to their original frozen layout.
Do not reuse an old runtime receipt for a newly composed input.

## Owner policy and gameplay fixture update - 2026-10-13

The initial removal of artificial commit headroom and the 85% stop rule is
superseded by the merged telemetry-only policy in PR3. Estimates and fresh
RAM/commit observations remain visible; they do not refuse admission or stop
work based on capacity or percentages. Exclusive leases, live process identity,
invalid-telemetry checks and occupied owner-client protections remain. See
docs/RESOURCE-WORKFLOW.md. The cross-API regression matrix also covers zero
available capacity and estimates larger than the machine without allocating them.

The private gameplay fixture can protect and clean up engine test bots only
while a protected local player is present on an explicitly isolated, private,
LAN-only CP dedicated with cheats disabled. It exposes no admin chat commands,
owner authentication, identity overrides or ban storage. The owner cancelled
all admin commands; do not reintroduce them. The helper enabled a protected
Spaceland shared-weapon witness, independently of owner gameplay acceptance.

The canonical implementations are these exports. Consumers must advance their
explicit dependency pin and regenerate source inputs to adopt this revision;
retained pre-migration copies do not automatically inherit the current policy.
