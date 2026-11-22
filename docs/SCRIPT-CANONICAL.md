# Script canonical names: the 4,095 slot table and how far it can go (a82, 17 Nov 2026)

`SL_GetCanonicalString` (0x140BFD340) gives every identifier that a script uses and the shipped token table does not hold (field names, function names, notify
names, the names of the production and custom scripts) one **canonical id**. The shipped table has **4,095 slots**; `MAX_CANONICAL_STRING exceeded` ends the script
load when it is full. Beast (`cp_final`) has 66 slots to spare with the production scripts, so no feature of more than about 60 new names can load there.
`src/native/script_canonical.cpp` raises the table: option `-script-canon-names <n>` (or `IW7_SCRIPT_CANON_NAMES`), **default 16,383**, `4095` is the shipped table untouched.
The decision rule of the work was "contained or stop": this page is the table of every holder that decided it.

## The shipped table (decoded from the code, `engine.py disasm 0x140BFD350`)

| Part | Where | What |
|---|---|---|
| block | pointer `0x1460B94F8`, taken by `FUN_140C03280` (called at the start of every script load, `0x140BFD560`) from a hunk (`0x14665A168`) of 0x20000 bytes + one page (the next hunk starts 0x21000 later: measured live) | hash region `(4095 + 1) x 4 = 0x4000` bytes (u32 per slot: name offset + 1, 0 = free, slot 0 never used), then the name buffer `(4095 + 1) x 28 = 0x1C000` bytes |
| name bytes used | `0x1460B9500` (i32) | `CANONICAL_STRING_BUFFER_SIZE exceeded` when `used + length > 0x1C000` |
| slot | `0x140BFD387` | `hash % 4095 + 1`, `hash = hash * 31 + c`, by a reciprocal multiply (`mov eax,0x100101; mul ebx; ...; imul eax,eax,0xFFF`) |
| probe | `0x140BFD3DD` | linear, `slot + 1`, 4095 wraps to 1; back at the start slot = `MAX_CANONICAL_STRING exceeded` |
| id returned | `0x140BFD496` `lea eax,[rsi+0x13FCC]` | 32 bit: `0x13FCC + slot`, so `0x13FCD` to `0x14FCB` |

Retail token ids (names the shipped token table knows) are `<= 0x13FCC` and do not use the table: the stack fix-up of a loaded script (`0x140C09DCC`, compare at `0x140C0A092`) takes an
operand `<= 0x13FCC` as it is and resolves a larger one through `FUN_140C0BD80`, which calls `SL_GetCanonicalString` for the inline text and stores the id back into the operand (a dword).

## Every holder of an id, and what a larger table needs

"Evidence": **code** = read in the decompiled or disassembled shipped code (`ops/engine/engine.py`) and the instruction index, **measured** = seen in a running game.

| Holder | Site | Width | Holds | Raising to 8,191 and to 16,383 | Evidence |
|---|---|---|---|---|---|
| table slot index | `0x140BFD387` (30 bytes), `0x140BFD3DD` (33 bytes) | 32 bit register code | `hash % 4095 + 1`, the probe wrap | rewritten: `hash % n + 1`, wrap at `n` (a `div` instead of the reciprocal: names are made at load time only) | code; same used count as the shipped table on cp_zmb (1,851 names, a79 and a82 runs) |
| hash region size | `0x140BFD3B5`, `0x140BFD45E` (imm32 `0x4000`) | 32 bit | offset of the name buffer | `(n + 1) x 4` (0x8000, 0x10000) | code |
| name buffer size | `0x140BFD427` (imm32 `0x1C000`) | 32 bit | bytes the buffer holds | `(n + 1) x 28` (0x38000, 0x70000); the stored offset is a u32 | code; name bytes 91,093 used at 4,979 names (measured) |
| block allocation | `0x140C03284` (23 bytes: the hunk call) and `0x140C032A6` (imm32 `0x20000`, the clear) | 64 bit pointer, 32 bit size | the block | **the hunk is exactly the shipped block (0x21000 reserved: the next hunk starts there): it cannot grow with the table.** The call becomes `mov rax, <own block>` (allocated once, `(n + 1) x 32` bytes + a page; the engine still clears it at every load); the clear takes the new size | code; hunk size measured live (`engine_live.py`, a82-base-final) |
| script operand | stack fix-up `0x140C0A09A`, `0x140C09E33`, `FUN_140C0BD80` | dword | the id of a field, function or notify name written back into the script's stack | none: 32 bit | code |
| class field list | `FUN_140C063D0` (call at `0x140C06410`) | dword in the temp hunk | the id of a class field | none: 32 bit | code |
| map entity keys | `FUN_140B1E790` (up to 0x40 keys), `FUN_1404A2AC0` | u32 | the id of an entity key name | none: 32 bit | code |
| variable name | child entry `+0xB` (u8) and `+0xC` (u16), 24 bit name | 24 bit | the id as the name of a child variable | none: below `0x40000` is a string name, `0x40000 + parent id` an object key, `0x800000 + n` an integer. **The ceiling: `0x13FCC + n < 0x40000`, so `n <= 180,275`** (the component accepts 65,535) | code (`docs/SCRIPT-VARIABLES.md` of the server repository, a45, a56); ids up to `0x17FCB` used in the runs below (measured) |
| key and hash | `(parent << 16) + (name >> 8)`, bucket `(parent * 0x65 + name) & mask` (a56, a62 sites) | 16 and 32 bit | `name >> 8` (10 bits at most) | none | code |
| name bound compares | 14 sites `cmp r,0x40000` in `0x140BFA7AF` to `0x140C09ED0` (VM) | 32 bit | string or object key | none: no instruction of the image compares a name with a value near `0x14FCB`, and none uses `-0x13FCC` (a side table indexed by `id - 0x13FCC` does not exist): the instruction index holds no immediate or displacement `0x13FCD` to `0x1FFFF` that compares a name | code (552 immediates read, the negative form searched) |
| script string table (MT) | `0x1460B9600`, 0x40000 nodes of 0x14 bytes, allocator `FUN_140BFDD10` (`MT_AllocIndex`) | 18 bit handle | script strings and other script memory | **none: a canonical id is not a string handle.** The handles in use reach about `0x18000` on cp_zmb, so they overlap the canonical range `0x13FCD`..: the two are different spaces that share the name field | measured (the bitmap of a live cp_zmb server, snapshot `server-20261111-cpzmb`) and code |
| notify and thread payloads | `(n << 8) + 0x10` in the thread entry (a79) | 24 bit | the name of a notify: a script string handle, not a canonical id | not a holder (dropped from the list) | code |
| client fork | `scripting.cpp`: detour on `SL_GetCanonicalString`, `unordered_map<unsigned, string>`; `functions.cpp:85` | any | id to text for the debugger and `get_canonical_string` | none | code |
| script checksum / save game | `DAT_14665A158`, ids folded in at `0x140C0BDD1` and `0x140C0A0B3`; read by `FUN_140C08F90` for the save header (`FUN_140402570`, `0x1404926AF`) | 32 bit | `hash * 31 + id` | the value differs from the shipped table's; only the save header reads it, and the game does not save in zombies | code |
| network | snapshots, netfields, the connect handshake | | | none holds an id: the compiled script keeps the identifier text in its stack, the id exists only in the process that loaded the script | code; measured: a client joined a raised server for a 5 minute hold (below) |
| files | `.gscbin`, the zone files | | | none holds an id (the text is in the stack) | code (`ops/Test-CanonicalBudget.ps1` inflates it and counts the strings) |

The ids of two processes differ whenever their tables differ (the slot of a name depends on the number of slots), which is harmless exactly because of the network and files rows.

## What was changed

`script_canonical.cpp` (component, always compiled, active by default): 7 edits, 102 bytes of code, each checked against the shipped bytes before any is written (one mismatch: nothing is
written, the process stops with the address). `-script-canon-names 4095` writes nothing. A process that is not a dedicated server also reads `IW7_SCRIPT_CANON_NAMES_CLIENT` first (a lab switch: the processes of one runner share an environment, and a session with a client of the shipped table against a raised server needs the two to differ). A table that exists already at the start of the component (the shipped one) refuses the change.
`tests/ops/script_canonical_test.py` checks every `before` against the shipped code, decodes every `after`, proves the slot arithmetic equal to the shipped division and the ids below the object keys.

## Measured (17 Nov 2026)

Headless gamelab sessions through the scheduler, private loopback, one engine bot, lab client built with `ServerModules,IsolatedLab,Debugger,Perf,AgentCapacity` from components `6df5cd4` (before main's a79 merge) and again from `e98a2e3`
(this branch merged with main): a result marked `m` is from the second client. The other side of every comparison is the same client with `IW7_SCRIPT_CANON_NAMES=4095` (the shipped table).
Evidence folders `%USERPROFILE%\Documents\IW7-Runtime\capacity\runs\a82-*` and `a82m-*`; commands and per-map numbers in `docs/BOSS-FIGHTS.md` of the server repository ("Name budget") and its changelog fragment `a82-canonical-name-table.md`.

| Question | Result |
|---|---|
| Beast, production scripts only (`-LoadOnly -BudgetMeter`) | 4,029 names used: 66 free of 4,095 in the shipped game, **12,354 free of 16,383** (m: the same); 28 Paris init lines, 0 script error blocks |
| Beast, production scripts and both boss fight scripts | **12,256 free of 16,383**, 28 init lines, 0 script error blocks (m: the same). With the shipped table: 0 free of 4,095, 0 init lines, exit 1, the load stops (negative control, m: the same) |
| Names used by the production scripts on the other maps (read from the process) | cp_zmb 1,662, cp_rave 3,290, cp_disco 3,587, cp_town 3,684; free in the 16,383 table 14,721, 13,093, 12,796, 12,699 (measured) |
| 1,000 new names called on Beast (library `canonnames`, plan `canon-names-beast-headless.json`) | PASS 5/5 steps, 2/2 expectations, 0 findings, `canonical_peak` 4,979 of 16,383 (m: the same). Shipped table: the session never reaches the map, the meter reads 4,095 of 4,095 (m: the same) |
| A second script load in one process | `map cp_final` from a running Spaceland server: the table is cleared and refilled (1,601 names, then 3,978 for Beast and the fixture, not their sum), no error (m, `a82m-rotate`) |
| a67 fill (`capacity-children-fill-headless`, 240,000 children) | PASS 30/30 steps, 17/17 expectations, 0 findings (a67: 30/30, 17/17); m: the same |
| 305 field, cp_zmb (`capacity-mixed-headless`: 200 plain, 25 clowns, 25 ghosts, 25 brutes, 30 greys) | PASS 141/141 steps, 131/131 expectations, 0 findings, alive 302 to 306 in every window (24 windows, about 12 minutes); children total peak 221,653 (m: 222,366; a79 on the shipped table: 220,693); server frame mean 43.3 ms, p99 53.5 (m: 45.7 ms, p99 56.4; a79: 45.1 ms, p99 70.3); canonical used 1,851 names, the count the shipped table showed in a79's run |
| Joined NetLab, Beast, production and boss scripts, 5 minute hold | PASS, join 58.8 s, 420.2 s, both sides the raised build. m: a **client of the shipped table** (`IW7_SCRIPT_CANON_NAMES_CLIENT=4095`; its log says `[script canonical] shipped table: 4095 names`) against the raised server (4,127 names loaded): PASS, join 60.1 s, 423.7 s, client and server alive at the end, 0 script errors in either log |
| A/B, `capacity-agents-held24-headless`, window `a24`, 3 pairs | server frame mean 2.779 ms (shipped) against 2.768 ms (raised), median 2.711 against 2.677, p99 3.695 against 3.850 (-0.4 %); m, a second set of 3 pairs: 2.598 against 2.627 ms (+1.1 %), median 2.531 against 2.561, p99 3.682 against 3.716; `iw7_sperf.py compare`: no function above the noise in either set. The two sets disagree in sign and the pairs differ by 3 % among themselves: the table is read at a script load only, nothing in a frame, and the difference is not shown below the 5 % that three runs a side can show |

## In production (22 Nov 2026)

The production native `CC865A71` (`Build-Voice -ServerModules -OwnerCheats -AgentCapacity` of components `77c67d63`, which
holds this change; its build manifest lists `script_canonical.cpp` `629EBDED`) runs on Canada (live) and Main (staged) since
21 Nov 2026, with no `-script-canon-names`: 16,383 names. Beast with every production script and the deployed mod: 4,076
names used, 12,307 free (19 with the table forced to 4,095); the retail Mephistopheles fight to the victory with and without
the boss fight module, 0 script errors (Forge, compressed time). The server repository's `docs/BEAST-CANONICAL-STRINGS.md`
has the runs; its `ops/Test-CanonicalBudget.ps1` fails below 64 free names on Beast.

## Not proven

- Any value of `-script-canon-names` other than 4,095 and 16,383 (the option accepts 4,095 to 65,535; the ids stay below `0x40000` by a static assert).
- A saved game (not done in a zombies match; the header checksum differs and nothing reads it back).
