# Contained community-download failures

Private source candidate, 2026-10-12. Ownership is limited to this directory and
the archived `src/client/component/download.cpp` patch. Creator, shared native
checkouts, voice, Main and runtime deployment are unchanged. Two local harness
compilations exceeded the source-only mission; see the incident below. The parent
integrates the reviewed commit into the central private PR; no upstream PR.

## Finding and correction

At Aurora pin `77e6d4d24e918ee363b3feee3735c3b889dff7d7`, download errors throw
through an asynchronous scheduler callback without a catch. The downloaded buffer
CRC is checked, but `write_file` is unchecked and itself ignores stream write/close
failure. A rejected disk write can therefore announce completion and reconnect.
These are source findings; no client crash was deliberately reproduced here.

The patch contains worker exceptions, returns a short English error through
`game::shared::menu_error` on `scheduler::main`, and keeps HKS notifications on
`scheduler::lui`. The actual pin's `game.cpp:50` calls
`Com_SetLocalizedErrorMessage`; `party.cpp:290` supplies the existing main-path
precedent. `ModDownload.lua:25` uses `mod_download_done` to close the progress
popup: it is a terminal cleanup event, including on error, not proof of success.
Only a successful terminal decision may call `party::connect` on main.

Each file uses an exclusive `CREATE_NEW` temporary in the destination directory:
bounded checked writes, `FlushFileBuffers`, checked close, exclusive reopen,
checked length and byte-for-byte readback, checked second close, then one
`MoveFileExW(REPLACE_EXISTING | WRITE_THROUGH)`. There is no delete-first step or
cross-volume copy fallback. The helper is local; `utils/io` is unchanged.

The active state starts before worker submission. Generation checks reject stale
UI callbacks, and cancellation is checked during transfer, writes, readback, before
publication and at the final main-thread connection decision. A cancellation
serial preserves the real `party::download_files` stop-then-start replacement
path while allowing a later stop to cancel that queued replacement.

Publication is **per file**, not a transaction across all three mod files. If a
later file fails, a previously committed verified file may remain; no connection
is attempted. Cancellation after the rename commit point may retain that valid
new file, while still suppressing connection. Failure before that point preserves
the old destination. OS/hardware crash durability and hostile concurrent folder
replacement are not established. Temporary cleanup is best effort on OS refusal.
If scheduler allocation itself fails, the worker still does not throw or reconnect,
but cannot guarantee delivery of a UI notification through the unavailable queue.

## Source verification and historical runner

Use the existing local native Git objects; no fetch, clone, native checkout edit,
game asset, actual HTTP, DLL injection or full game build is needed to verify:

```powershell
python tools-source/community-download/verify_archive.py --native-source C:/Users/ezvalo/Documents/IW7-Paris-Server/tools/iw7-mod-contrib
```

`verify_archive.py` checks base/result/patch SHA-256, the complete transformation
and the unchanged upstream license. The runner additionally applies the patch
with real `git apply --check`/`git apply` to a one-file scratch fixture and compiles
that exact reconstructed C++ file using installed MSVC, C++20, `/W4 /WX /EHsc`.
It does not compile a separately reimplemented transaction algorithm.

The unadmitted harness reported 43 passing cases. They cover missing HTTP/URL,
curl refusal, bad status/CRC, standard
and nonstandard exceptions, create/write/short-write/flush/close/reopen/size/read/
short-read/corruption/replace failures, real Windows destination locking, first
install and replacement, cancellation windows, deferred retries, stale callbacks,
shutdown, scheduler allocation failure and a later file failing in a multi-file
set. HTTP, CRC and scheduler adapters are mocked; CRC uses the independently
implemented IEEE algorithm and native `123456789 -> 2639F4CB` vector. Files are
real Windows files, with fault injection around individual Win32 calls.

`validation.json` binds the functional source/harness hashes but sets overall
`passed:false` and `admitted_pipeline_passed:false`. Ignored `.scratch/`
retains small compile logs, harness executables and temporary fixtures; none is
part of the source archive. The first archive reconstruction comparison failed
because local Git converted LF to CRLF. Per-command `core.autocrlf=false` fixed
the verifier; no global setting changed. The first 40 cases passed before the
real party stop/start call sequence prompted the serial guard and three added
regression cases. These are offline component tests, not a full native build,
rendered UI witness, download over a real server, or owner acceptance.

## Source-only incident: no retrospective admission or closure

The agent incorrectly treated this compiled harness as a permitted lightweight
test and ran it twice without reservation, original Job Object supervision,
historical PID/creation identities or descendant accounting. This exceeded the
source/preparation assignment. The 40-case and 43-case executions were at
07:37:59--07:38:04Z and 07:40:53--07:40:58Z on 2026-10-12 (09:38 and 09:41 Paris).
Tool wall times were 4.6880442 and 5.1836618 seconds for the whole Python calls;
neither compiler-only duration nor memory/commit peaks were measured. The only
execution bounds were subprocess timeouts of 90 seconds for compile and 30 for
the harness. Returning zero from those subprocesses did not establish descendants'
closure. No admission or full native pipeline pass is claimed.

At 07:49:07.911Z a targeted observation retained VCTIP PID29324, reported parent
PID32792, creation07:38:02.967Z and its image hash. The parent PID was absent.
This overlaps the first compilation, but no historical compiler identity proves
the relationship. The earlier zero-match check filtered only paths containing
this archive; it could miss a pathless descendant and was not a closure proof.
The residual remains preserved, without guessed attribution or termination.
The parent's later observation that the unchanged scheduler does not classify
VCTIP as a builder does not change this uncertainty.

The original command files, logs, EXE/OBJ and receipts remain ignored in
`.scratch/harness-7dfozczw` (2598031 bytes) and `.scratch/harness-gwstj0b0`
(2666867 bytes), plus the pre-compilation reconstruction failure (9803 bytes).
The sanitized record preserves measured times, sizes and hashes without changing
the original receipts. Future repetition requires reviewed Plan/original-job
supervision and complete admission; the old direct runner is not an approved
execution route. No further native invocation was made for this incident report.

## Review and subsequent build plan (not executed)

Review the single native patch and receipt before integrating. In the central
builder, add an explicitly enabled, pin-and-base-hash-checked application step
after checkout/overlays and before native compilation. At the audited main this
is near `ops/Build-Voice.ps1:274`; the existing cache overlay changes `party.cpp`
and is independent. Accept only the pinned base or this exact result, preserve
other edits, and include the patch/result hashes in the build manifest. Current
Build-Voice does **not** apply this archive automatically; running it unchanged
would not build this correction.

Then, with reviewed source, an owned existing native checkout and the parent's
single admitted build slot, use the current isolated Modules build pipeline with
one build job (existing estimate 4 GiB physical / 6 GiB commit). Compile/link and
inspect the exact resulting native manifest first. A later separately authorized
protected candidate session can exercise first join, cache reuse, HTTP refusal,
bad CRC and cancellation while observing rendered notices. Main remains outside
that experiment. No reservation, full build or game run is included here.

The base source remains governed by the exact retained `LICENSE.upstream`.
No license claim is added for unrelated private scripts or game assets.
