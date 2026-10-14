# Metadata-bound NTFS stock aliases

`ops/Stock-Links.Core.ps1` owns a generic filesystem transaction. It creates a
new target's explicit retail-file aliases on the same local NTFS volume. It
never copies retail data, reads/hashes retail content, writes shared file
attributes, overwrites an existing target or prepares a client. Directory and
journal metadata still consumes filesystem space. Logical bytes are not new
physical retail bytes.

Server policy, stock selection, independent mutable files, marker, native
candidate binary, process protection, lease reservation/release and host exit
belong to the caller. This helper does not qualify the pathset as sufficient
for a game or change a frozen source cohort. A fixed asset-build input is not
proof of sufficient server stock. Real preparation still needs the separately
authorized candidate path and GO; source fixtures do not supply that GO.

## Caller contract

Import is functions-only. The small C# provider loads lazily. Use a newly
composed source package pinned to the reviewed Native revision, never edit an
older package or retained launch helper.

1. `Read-IW7StockLinkPlan -ManifestPath <small JSON> -ExpectedManifestSHA256
   <reviewed SHA256> -SourceRoot <exact source> -TargetRoot <exact absent target>`
   verifies the bounded manifest, its exact roots, relative pathset and totals.
   It hashes only that JSON. The schema is `iw7.server-only-link-plan/1` with
   `source`, `target`, `planned_files`, `logical_bytes`, literal false
   `stock_content_read`, `hashes_computed`, `links_created`,
   `client_clone_created`, zero `stock_bytes_copied`, and `files` rows containing
   `relative`, `bytes`, `volume`, `file_id`, `links`, `attributes`, `created_ns`
   and `modified_ns`. Full unsigned volume serials are decimal strings or exact
   JSON integers, never narrowed to signed Int64. `file_id` is the low 64 bits
   from the source plan; preflight captures and binds the full 128-bit ID.
2. Keep the existing original NoExit caller root in AppDomain data. Invoke
   `New-IW7StockLinkTransaction -Plan <plan> -OwnerRoot <original IDictionary>
   -RetentionKey <same AppDomain key> -TransactionSlot <unused key>
   -LeaseToken <current caller token> -ValidateCaller <scriptblock>
   -JournalPath <new local JSONL outside source and target>`. The scriptblock accepts
   `(LeaseToken, TargetRoot)` and **throws** unless the original caller's actual
   host protection, lease, target and operation authorization remain valid.
   It must check existing native/resource helpers, not reconstruct proof from
   JSON. The helper neither reserves nor releases that lease.
3. The returned actual context is placed in `OwnerRoot[TransactionSlot]`
   before preflight or creation. `Invoke-IW7StockLinkPreflight <context>` rebinds
   the manifest SHA, validates live NTFS metadata and retains actual source,
   ancestor and target-parent handles. `Invoke-IW7StockLinkApply <context>` may
   perform preflight automatically. The create-only journal is published in
   that same context and flushed before each alias/directory side effect.
4. Known success returns `iw7.stock-links-prepared/1`, `Prepared=true`,
   `SourcePreserved=true`, counts, `RetailDataBytesCopied=0` and
   `RuntimeValidated=false`. Actual filesystem guards and writer close; the
   original caller retains the context and journal identity for later undo.
   Only the caller may decide whether its entire operation may release a lease
   or exit. Alias preparation alone does not establish runtime acceptance.
5. On failure, inspect `Phase`, `Failure` and `UnknownCreation` in that same
   root. Retain the same host, context, native references, guards and journal.
   Never reconstruct a context from a receipt, release a lease on unknown
   state, clear AppDomain data, or call the internal guard closer on failure.
   `UnknownCreation=true` refuses deletion until the original caller resolves
   the creation identity. There is no path-based fallback or automatic cleanup.
6. `Undo-IW7StockLinkTransaction <same context>` validates current original
   source names, link counts, created aliases/directories and the journal.
   After a successful apply it reopens only the recorded journal identity and
   appends rollback events. It unlinks only recorded aliases by a bound handle
   and removes only recorded empty directories by identity. Replacement,
   missing source, changed journal, reparse or remaining mutable/unowned entries
   refuse completion and preserve the context. It never recursively deletes,
   clears readonly attributes or removes caller-owned cfg/bank/marker files.
   The caller must remove its independently owned mutable files by its own
   guarded procedure before retrying directory closure.

The API is for a trusted reviewed caller in one live host. AppDomain references,
leases and Windows sharing are operational guards, not an OS security sandbox
against arbitrary external changes. Hardlink aliases share the original data:
the caller must not write retail content through them. No automatic attribute
change makes them readonly.

For its independent small mutable files, the caller may reuse the same provider
after `Initialize-IW7StockLinkNtfs`. `IW7StockLinksV1.Ntfs.CreateDirectoryOwned`
returns the original create-only directory SafeFileHandle. Publish it in the
same caller root before continuing; `Inspect(handle)` supplies its full identity.
A caller-created `FileStream(CreateNew, ...)` likewise exposes its original
`SafeFileHandle` for identity capture. These entries are not added to the stock
transaction's ownership lists. The caller alone owns their data writes, limits,
receipt and recovery. Before cleanup, validate the original root/lease, close
only known original writers/guards, then use `OpenOwnedDelete(path)`, compare
`Inspect(handle).Identity` with the original record and `UnlinkByHandle(handle)`.
Dispose the bound deletion handle after completion. Never adopt a replacement,
clear shared attributes, recursively remove directories, or release on unknown
identity. This exposes the existing small filesystem primitives, not a new
process controller.

## Identity and shared metadata

Each object is identified by full volume serial plus 128-bit NTFS file ID.
Live type, size, allocated size, attributes, creation/last-write/last-access
times and baseline link count are checked. Source aliases sharing an ID are
grouped; aliases outside the pathset remain included in the baseline count.
The projected count may not exceed 1023. Reparse points, ambiguous relative
paths, traversal, device names, absent parents and cross-volume fallback refuse.

Hardlink creation can set the shared Archive bit. Therefore the manifest and
live source must already have Archive set. Missing Archive refuses before any
target creation; the helper never sets it on the source. Link count and
ChangeTime naturally change during link/unlink and are recorded, not described
as invariant. Other checked metadata must remain unchanged.

Source handles request read access to enforce denial of concurrent writers;
the provider calls no retail-content read API. Source ancestor guards deny
rename/delete. New directories use `NtCreateFile(FILE_CREATE,
FILE_DIRECTORY_FILE)` to return the original creation handle atomically, rather
than creating a path and adopting a later reopened directory. Rollback delete
handles allow existing source readers but deny concurrent write/delete, and
`FILE_DISPOSITION_EX` deletes the opened name with POSIX semantics and
IGNORE_READONLY_ATTRIBUTE. The shared readonly attribute is never cleared.

Primary API contracts: [FILE_ID_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info),
[FILE_BASIC_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_basic_info),
[CreateHardLinkW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createhardlinkw),
[file/directory create dispositions](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-zwcreatefile).

## Local validation, 2026-10-14

`tests/ops/stock_links_test.ps1` uses only its own small GUID-scoped temporary
NTFS files. It exercises real readonly and Archive-only aliases, duplicate
source IDs, aliases outside the pathset, unchanged shared metadata, known
success and partial rollback, atomic directory guards, writer exclusion,
changed manifest, missing source, replaced journal/alias, original-root identity,
retained failure references, mutable-content preservation and reparse/traversal
refusal. Its cleanup never follows reparses or clears shared attributes.

Initial directory metadata-only handles did not prevent a rename. That fixture
failed and the provider now requests directory-list/read access to make the
sharing guard effective. This correction and the passing fixture do not prove
real stock preparation or engine startup. No real stock Apply, stock-content
scan/hash, production reservation, full game copy, C++ build, game launch, Main
mutation or owner gameplay acceptance is claimed by this change.

The first concurrent source merge temporarily combined two check entries into
an invalid JSON object. That local source-check attempt stopped before running
tests; a corrective commit preserves both entries. The corrected, freshly
composed source package passes the stock, path, source-workspace and HUD groups.
