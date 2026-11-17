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
written, the process stops with the address). `-script-canon-names 4095` writes nothing. A table that exists already at the start of the component (the shipped one) refuses the change.
`tests/ops/script_canonical_test.py` checks every `before` against the shipped code, decodes every `after`, proves the slot arithmetic equal to the shipped division and the ids below the object keys.

## Measured

See `docs/SCRIPT-CANONICAL-RESULTS.md` of the paris server repository (BOSS-FIGHTS "Name budget" and the evidence folder names) once the proof runs are in; this page is the engine side.
