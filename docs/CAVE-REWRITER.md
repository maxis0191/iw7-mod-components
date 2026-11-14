# Cave rewriter: grow an instruction by moving it to a code cave

Status (14 Nov 2026): version 1 built and proven in the headless game (see "Proof"). Version 2 (branches in windows, backward and mixed windows, retargets) is proven offline only; its C++ part is not built yet.

A1 stage 2 (14 Nov 2026, commit 8c195ee): the 49 table-1 instructions (a1-table1.*, 48 caves) are the live table of `agent_capacity_caves.inc`, built and run: headless run at 24 agents passes 13/13 and a fault in cave 29 (`-agent-capacity-cave-fault`, mask 1<<29, env `IW7_AGENT_CAPACITY_CAVE_FAULT=536870912`) exits with an illegal instruction at the first zombies. The proof plan (`proof-zero-change.*`) stays in the repository, not in the build; the sites test takes the live plan from the header line of the `.inc`.

## What it is for

The engine's 8-bit displacements and immediates (`mov eax, [rdx+rbx+0x24]`) cannot hold the values the capacity patch
needs (`0x3F1C`): the instruction becomes longer, so it does not fit in place. The cave rewriter moves the instruction,
with the whole instructions after it that are needed to make 5 bytes, into a cave, re-encodes the one that must grow,
and puts `jmp rel32` where the window was. The first users are the 49 table-1 instructions of the A1 change set
(`a1-change-set.md`, parts A and G) and the ~30 one-byte immediates above 100 agents (hand-over row 29).

Two halves, one format:

| Half | File | Runs |
| --- | --- | --- |
| Planner (offline, Python) | `ops/engine/cave_plan.py` | on the working machine, against the analysed image and the engine database |
| Run time (C++) | `src/native/agent_capacity.cpp`, `cave()`; table `src/native/agent_capacity_caves.inc` (generated, committed) | at start, inside the all-or-nothing patch transaction, only with `-agent-capacity` |

## Use

```
python -B ops/engine/cave_plan.py requests.json -o plan.json          # plan (exit 2 and nothing written on a refusal)
python -B ops/engine/cave_plan.py --emit-cpp plan.json -o src/native/agent_capacity_caves.inc
python -B tests/ops/cave_plan_test.py                                  # unit tests, no game, no database
python -B tests/ops/agent_capacity_sites_test.py                       # every patch site and every cave window against the shipped bytes
```

A request is `{"address": "0x140ADA146", "kind": "disp", "new_disp": 20, "force32": true}` (change the displacement of the
instruction's memory operand; an 8-bit displacement is re-encoded as 32-bit when the new value does not fit a signed byte
or when `force32` is set) or `{"address": ..., "kind": "bytes", "new_bytes": "hex"}` (replace that one instruction by the
given bytes of any length; they must be position independent: no rip-relative operand, no relative branch). The input is a
JSON list or `{"requests": [...]}`. Image and database default to the RE lab (`docs/ENGINE.md`, `IW7_RE_LAB`); without the
database the planner still runs, with the byte scans only (it says so).

`--dry-run` plans every request ALONE and writes a per-request accepted/refused table (exit 0): used to ask, before any build, which sites of a change set the cave technique can serve.

### How to add a site

1. Find the instruction (A1 change set row, or `engine.py disasm`), write one request per instruction. Two requests whose
   windows overlap become one cave with two changes; nothing to do by hand.
2. Run the planner. A refusal names the instruction and the rule. Fix the request (another instruction of the pair) or
   handle that site differently; never edit the plan by hand.
3. Keep the plan file under `ops/engine/caves/` (`<name>.requests.json` and its output `<name>.json`), regenerate
   `agent_capacity_caves.inc` from every plan that must be live, commit all of them. The sites test fails when the `.inc`
   disagrees with the plan files or with the shipped bytes.
4. Build and run. The caves of the table are installed with the other patches; the log line says `caves=N`.

## Plan format

Per cave: `window_start`, `window_len` (smallest run of whole instructions from the start covering at least 5 bytes, or
more when merged), `old_bytes`, `cave_bytes`, `fixups` (list of `{offset, size: 4, end, target}`), `return_address`
(= start + length) and `changes` (list; one entry per changed instruction: address, kind, old and new bytes, new_disp).
`end` is the offset of the instruction END inside `cave_bytes`: a rip-relative displacement is relative to the end of the
instruction, not to the end of the 4-byte field, which differs when an immediate follows (`cmp dword [rip+x], 5`). The
run time computes `new = target - (cave address + end)`.

## Refusal rules, and why each exists

The planner refuses the whole plan (reasons on stderr, exit code 2, nothing written) when:

| Rule | Why |
| --- | --- |
| the window contains `ret`, `int3` (or another `int`), `iret` | execution would leave the cave or trap inside it; a `ret` also ends the window's flow so the jump back is never reached |
| the window contains `loop*`, `jrcxz`, `jecxz`, `xbegin`, a branch with prefixes, or a branch into the middle of a window instruction | these have no rel32 form or no matching cave instruction. Direct `jmp`/`jcc` are allowed and re-encoded (see "Windows, branches and retargets"); indirect `jmp` is allowed; rip-relative memory operands become fixups |
| the window contains a `call` of ANY form (relative, through a register, through memory, rip-relative memory) | a call executed from the cave leaves a return address INSIDE cave memory, which has no unwind data. The engine unwinds the stack on its error path (`Com_Error` uses longjmp, which on x64 Windows walks unwind data), so an error raised below such a call would mis-unwind. Rule: no call and no instruction that pushes a return address in a window |
| any byte of the window after its first is the target of a branch, call or data reference from anywhere in the image (unless every such reference can be retargeted and no other window avoids it) | the window after the first byte becomes `jmp` operand bytes and `int3`: a jump into it crashes. Checked by (1) the engine database's `refs` and `calls` tables over the whole range, (2) a byte scan of every executable section for rel32 and rel8 branches landing in it, (3) a scan of all sections for 8-byte absolute pointers and 4-byte image-relative values (jump tables) equal to an interior instruction start |
| two requests ask for the same instruction | ambiguous |
| a request is not at an instruction boundary of its window | the decode disagrees with the request |
| `disp` kind: the instruction has no single ModRM memory operand, has a register operand (`mod 11`), is rip-relative (its displacement is an address, not a table offset) or is EVEX (its 8-bit displacement is scaled) | the re-encoding is not defined for these |
| `bytes` kind: new bytes do not decode completely, or contain a rip-relative operand or a relative branch | they would be moved to another address with no fixup for them |
| a rip-relative target is more than 2 GB from the cave | the 32-bit field cannot reach it (checked in the self-check, and again at run time) |
| the self-check below finds any difference | an encoder bug must never reach the game |

Merging: requests whose windows overlap are merged into one cave (the window runs from the first start to cover the last
changed instruction, at least 5 bytes); the rules apply to the merged window. No cave may branch to, or have an incoming
branch retargeted from, the interior of another cave's window (refused).

The encoder handles ModRM `mod 00 -> 01 -> 10` with and without SIB and REX, `mod 00` with no displacement (base not
rbp/r13: that form is rip-relative or disp32 and is handled as such), and SIB with no base (disp32 kept, value replaced).
It never shrinks a displacement. The unit test runs it over rex x opcode x mod x rm x SIB x displacement x new value
(more than 5,000 accepted encodings) and decodes every result with capstone.

### Self-check (built in, every request, before anything is written)

The cave bytes are decoded again from scratch with the fixups applied for a hypothetical cave address (`0x150000000`) and
compared instruction by instruction with the original window decoded at its own address: same instruction id and mnemonic,
same operands (registers, immediates, memory base/index/scale/segment/displacement, sizes), rip-relative operands resolved
to the same absolute target, except the one intended displacement; the cave must not contain a `ret`, `int3` or relative
branch, and must have exactly as many instructions as the window (replacement bytes: exactly the given bytes). Any
difference refuses the plan. The unit tests feed it deliberately wrong displacements, registers, opcodes, fixups and an
extra instruction.

## What the cross-reference check does not cover (honest limits)

- The database's `refs` and `calls` are what Ghidra found, plus the planner's own byte scans. The scans read every byte as
  a possible opcode (conservative: a spurious refusal, never a missed branch). To stop `shl rdx, 6` (`48 c1 e2 06`, where
  `e2 06` looks like `loop`) from refusing real sites, a hit is dropped when the database's function containing it decodes
  linearly to exactly the function's end and the hit is not an instruction start in it; where there is no such function
  (the protected span, no database) every hit stays.
- A target computed at run time (`jmp rax` from a table the scan does not recognise, a return address, an exception
  handler resuming at an address) is not seen. The engine's own jump tables are 4-byte image-relative values and are
  found; tables built at run time are not.
- Exception and unwind data: the cave has no `RUNTIME_FUNCTION` entry, so no stack walk or longjmp may cross it. That is why a window may contain no call of any form (see the refusal table): with no call, nothing below the cave can run while its frame is on the stack, and the cave itself cannot throw except by a fault of its own instructions.
- A fault inside a cave is reported by the crash handler with an address in cave memory and "not in any module" (the proof below: rip `0x150280000`). To map it back: at start the component prints one line per cave (up to 32 caves), `[agent capacity] cave k: window <start>+<length> -> cave <first>..<last>`; the cave whose range holds the address is the window to look at (`window_start` in the plan and in `agent_capacity_caves.inc`, same order). The crash report's caller list still names the engine function that jumped to the window.
- No other thread may be running the window while it is patched: the patch is made at start, before game threads run.

## Run time (`agent_capacity.cpp`)

`cave(window_start, old_bytes, cave_bytes, fixups)`: checks the stock bytes of the window (like `add`), takes executable
memory within 2 GB of the image (the same `VirtualAlloc` scan as `reserve`, one region for all caves, pre-filled with
`int3`), writes the cave bytes, re-bases every fixup (`target - (cave + end)`, range-checked), appends `jmp rel32` back to
`window_start + length`, and queues the window as `E9 rel32` + `int3` fill through `add1`, so the existing sorted overlap
check and the all-or-nothing transaction cover it. Nothing is counted inside a cave (a counter changes flags).

Test switch `-agent-capacity-cave-fault [mask]` (bit k = cave k of the table, no value = all): the cave bytes become `ud2`.
It proves that a cave runs without a counter: the process must die with an illegal instruction inside the cave memory. It
is inert unless given.

## Windows, branches and retargets (second version, 14 Nov 2026)

**Branches inside a window.** `jmp` and `jcc` (rel8 or rel32) are allowed in a window. In the cave each is the rel32 form
(`E9 rel32`, `0F 8x rel32`). A target outside the window becomes a fixup of kind `branch` (same arithmetic as the rip
fixups: `target - (cave + end)`, `end` = end of the branch instruction); a target inside the window becomes a cave-internal
displacement to the matching instruction (no fixup). A target that is the middle of a window instruction, a branch with
prefixes (hint bytes), `jrcxz`, `loop*` and `xbegin` are refused. `call` stays refused in every form. The self-check compares
branch targets by resolved address (outside) or by the matching cave instruction (inside).

**Window choice.** The planner tries, in order, and takes the first window that passes every rule: (1) forward from the
changed instruction (at least 5 bytes); (2) backward, ending at the end of the changed instruction (the nearest earlier
instruction boundary that gives 5 bytes); (3) every mixed window that contains the changed instruction and is at most 24
bytes, shortest first. Boundaries before the site come from the linear decode of its function (database function range,
trusted only when it ends exactly at the function's end and lands on the site; otherwise only forward windows are tried). The
window START may be a branch target (the jump to the cave sits there); no other instruction of the window may be one.
Several requests whose chosen windows overlap are re-planned as one group.

**Retargeting.** Only when no window of the list avoids an incoming reference: each reference is rewritten to the matching
cave instruction, recorded in the plan (`retargets`: kind, instruction address, field, stock bytes, original target, cave
offset) and in `agent_capacity_caves.inc` (`{field, kind, stock value, cave offset}`). Forms: a `jmp/jcc rel32` (new rel32 =
cave + offset - (field + 4); the branch must be an instruction start of its function's decode) and a 4-byte, 4-aligned
image-relative jump-table entry in a non-code section (new value = cave + offset - image base). A rel8 branch, a call, an
8-byte pointer, a 4-byte value inside code or unaligned, and any database reference of another form stay refusals with that
reason. The run time (`cave()`) checks each field against its stock value in the same transaction and refuses at start, with
a clear message, if the cave is not above the image base and within 2 GB for a table entry. `reserve_code` takes memory from
`0x150000000` upward: above the image base (`0x140000000`) and within 2 GB of every window of the image.

Status: the retarget code in `agent_capacity.cpp` and the emitter/parser are tested offline only (unit tests and the sites
test); the C++ of this piece is NOT built or run (no build was part of it). None of the real A1 sites needs a retarget (below).

Alignment gaps: a byte-scan hit lying between two analysed functions less than 16 bytes apart is padding, not an
instruction, and is dropped.

## Dry runs over the A1 change set (14 Nov 2026, no build, no game)

(a) The five sites the first version refused, each alone, with the table-1 REAL new values (`a1-refused5.requests.json`,
`a1-refused5.result.json`): all five are accepted, none needs a retarget.

| Site | Window | Chosen | Why |
| --- | --- | --- | --- |
| `140454343` | `140454343`+9 | forward | forward window; the rel8 at `1404542EE` that blocked it lies in the 5-byte alignment gap between two functions (not an instruction): dropped |
| `1404A3AB1` | `1404A3AAF`+6 | backward | forward window refused (a 4-byte value equal to the image-relative address sits at `1405DD687`, inside code, unaligned: not a table); backward window passes |
| `1404A4A7D` | `1404A4A79`+8 | backward | forward window refused (rel8 at `1404A4A49` into it cannot be retargeted); backward window passes |
| `1405ECAE6` | `1405ECAE6`+6 | forward | forward window; the `jle` inside it is re-encoded as rel32 to the original target |
| `140AE202D` | `140AE202D`+10 | forward | forward window; the `jge` inside it is re-encoded as rel32 to the original target |

(b) All 48 cave instructions of the 49 table-1 instructions in ONE plan (`a1-table1.requests.json`, `a1-table1.plan.json`),
real new values: DIRECT and FORM-lea displacement d becomes d + 0x3EF8 (disp32); the add forms, FORM-BIAS, the inserted add
and the WALK start are the change set's own new bytes. The accessor `FUN_140AE2D10` is the 49th: part B's 16-byte in-place
rewrite at `140AE2D32` (stock bytes checked: `488b41084883c01048c1e2064803c2c3`; new bytes
`48c1e20648035108488d82083f0000c3` decode as shl, add, lea, ret) needs no cave. Result: **47 caves** for 48 changes,
**1 merged window** (`140AE2029`: two changes), 45 forward and 2 backward windows, **0 references retargeted**,
**0 sites refused**, 2 branch fixups, 1 rip fixup, longest window 11 bytes. The first version (`a1-dry-run.*`, kept as the
record) accepted 44 of 49 with unchanged displacements.

## Proof (14 Nov 2026, components `585b04f`, one lab client, headless, 24 agents)

Four zero-change caves (`ops/engine/caves/proof-zero-change.*`): each instruction is re-encoded from disp8 to disp32 with the
SAME displacement (`force32`) and moved to a cave. Windows (stock bytes -> cave bytes):

| Window | Function | Stock | Cave |
| --- | --- | --- | --- |
| `140ADABFC` (6) | FUN_140ADABD0 (A.20) | `8b440a1485c0` mov eax,[rdx+rcx+0x14]; test eax,eax | `8b840a1400000085c0` |
| `140ADBA7E` (7) | FUN_140ADB8E0 (A.23) | `2b4c1a1483e964` sub ecx,[rdx+rbx+0x14]; sub ecx,0x64 | `2b8c1a1400000083e964` |
| `140ADC274` (6) | FUN_140ADC1E0 (A.25) | `8b441a1485c0` | `8b841a1400000085c0` (not reached, see below) |
| `140AE2029` (8) | FUN_140AE2000 (A.29) | `8b44132439440b24` | `8b84132400000039440b24` |

Plan `capacity-agents-headless.json` copied with the 78 phase removed (cap held at 24, same conditions: normal zombies, damage
refill, protected bot, round 30, 20 s window), run folders `IW7-Runtime\capacityuns\cave-ok` and `cave-ud2`.

- Clean run (4 caves, 514 patches): PASS 13/13 steps, 5/5 expectations, 24 agents alive, 141 hits on the bot in the 20 s
  window (h4: 162, no cave), 24 killed, no script error, no crash; server frame at 24 alive mean 3.72 ms, median 3.59, p99 5.0
  (400 frames; h4 6.76 ms on a busier machine: no regression).
- Execution by exclusion: `IW7_AGENT_CAPACITY_CAVE_FAULT=<mask>` (also `-agent-capacity-cave-fault`) turns one cave into `ud2`.
  Cave 0: crash 76 s in, 0xC000001D at 0x150280000 (cave memory), from sub_140AFE4B0. Cave 1: exit code 0xC000001D at step 3
  (15 s, first zombies). Cave 3: exit code 0xC000001D at step 5. Cave 2 (`140ADC274`): the run passed: that instruction is not
  reached in a 105 s round-30 run (the function is only called under a condition the bot scenario does not meet). Earlier
  builds: `140ADA146` and `140ADB30F` were also never reached, which is why they were replaced; a cave whose fault run passes is
  not proven to run.
- Only the cave 0 crash left a dump (the others ended by exit code; the dump writer did not fire for those).
- One build served all runs: the fault switch makes the "second build with `ud2`" unnecessary.


## Frame grow: more stack room at the top of a frame (15 Nov 2026)

Status: planner, tests and run-time application built; see "Frame grow proof" below for what the game has shown.

**What it is for.** A function whose overrun array is its highest local (the array ends at the stack-protector cookie) cannot be
fixed by widening the array in place. Frame grow moves everything BELOW the array top down by X bytes and leaves everything at or
above it where it was relative to the CALLER, so the array gains X bytes at its top. First user: `FUN_1403E61B0` (a 71-entry array
of 32-byte entries under the cookie, filled by two unbounded loops; run h6 died on its cookie check with 78 agents alive). Facts and
the full access table: `a13-frame-facts.md` (notes folder).

```
python -B ops/engine/cave_plan.py frame-grow --function 0x1403E61B0 --array-top 0xCC0 --extra 2272 --max-extra 7136 -o plan.json
python -B ops/engine/cave_plan.py --emit-cpp plan.json -o src/native/agent_capacity_frame_fields.inc              # field table
python -B ops/engine/cave_plan.py --emit-cpp --frame-cave plan.json -o src/native/agent_capacity_frame_cave.inc  # probe cave line
python -B ops/engine/unwind_info.py 0x1403E61B0                                                                   # the unwind data of any function
python -B tests/ops/frame_grow_test.py            # hand-built functions, every change kind and every refusal
python -B tests/ops/agent_capacity_sites_test.py  # includes "FrameGrow": the tables against the shipped bytes
```
The command lines of the live plan are in `ops/engine/caves/frame-1403e61b0.command.txt`; the plan is `frame-1403e61b0.frame.json`.
`--array-top` is the offset from rsp after the prologue (S) where the grown region ends (here the cookie, S+0xCC0). `--extra` is X
for the self-check, `--max-extra` the largest X the run time may use (the probe cave is planned for it).

**What changes (every item is a field: address, width, stock value, unit in bytes, sign; at run time new = stock + sign * X / unit).**

| Change | Field | Sign |
| --- | --- | --- |
| `sub rsp, F` | imm32 (or, when the grown frame reaches a page, the cave below) | + |
| every `add rsp, F` epilogue | imm32 | + |
| frame base `lea rbp,[r11-d]` (or `[rsp+d]` before the `sub`) | disp32 | - |
| every `[rsp/rbp+d]` access at or above the array top (cookie store and load, xmm saves restored through rsp) | disp32 | + |
| every access through a register that holds the ENTRY rsp (`r11`/`rax` copies) that lies BELOW the array top | disp32 | - |
| UNWIND_INFO ALLOC_LARGE size | 16-bit (units of 8) or 32-bit operand | + |
| UNWIND_INFO SAVE_NONVOL / SAVE_XMM128 at or above the array top (in every chained chunk) | 16/32-bit operand (units 8/16/1) | + |
| GS handler data (`__GSHandlerCheck`): cookie offset from the establisher frame | dword, low 3 bits are flags | + |

Accesses through `r11` at or above the top (the xmm saves at `[r11-0x58]`) and accesses through `rsp`/`rbp` below the top need no change.
X must be a multiple of 16 (movaps alignment, the 16-unit xmm operands).

**How the planner reads the function.** A linear symbolic walk (`walk()` in `frame_grow.py`) follows rsp, the frame base `rbp`
and the volatile copies of the entry rsp (`rax`, `r10`, `r11`, valid until a call, a branch or a write) through prologue, body and
epilogue (stage `pro` until the one `sub rsp, imm32`, `body`, `epi` after `add rsp, F` until `ret`/`jmp`). Every stack access gets
its offset from the caller's stack pointer and from S, and whether its base moves with the frame; the change of its displacement
follows (moving base: +X at or above the top, 0 below; non-moving base: 0 at or above, -X below).

**The page-touch cave.** A frame of one page or more must touch its pages in order (the stock 0xD58 frame needs no probe, the grown
one does, already at 24 agents: X = 2272). When F + max X >= 0x1000 the `sub rsp` goes through the existing cave machinery as a `bytes`
request: `test byte [rsp-0x1000*k], 0` for k = 1..ceil((F+Xmax)/0x1000), then `sub rsp, F+Xmax`. The probes read below the pushed
registers, top down, one per page, so the guard page moves one page at a time; they come BEFORE the `sub`, which overwrites all six
arithmetic flags, so no flag analysis is needed, and no register is used and nothing is written. The cave is planned for the largest
X; the run time patches only the immediate (offset in the table) and refuses an X above the planned maximum. A smaller actual X
just probes some pages below its frame (harmless reads of unused stack).

**Refusals** (exit 2, nothing written; each has a unit test): a field that must change but is 8 bits wide (`sub rsp, imm8`, `add rsp,
imm8`, a disp8 at or above the top); dynamic stack adjustment (`sub rsp, reg`, `lea rsp`, `mov rsp, ..`, `leave`, `push`/`pop` in the
body, a second `sub rsp`); an epilogue that is not `add rsp, F`; `lea` of stack memory at or above the array top (the pointer
would escape); a stack pointer copied into a register or memory; an indexed stack access; an access that straddles the top; rbp used
without a frame base; unwind data not handled (ALLOC_SMALL, unknown exception handler, handler flag bits, version 2, chunks not
chained to the primary, a cookie offset the code does not access, an ALLOC_LARGE that differs from the code's frame, a size operand
that overflows 16 bits); a return outside an epilogue.

**Self-check (built in, before anything is written).** The plan is applied to a copy of the function for X = the plan's X, its largest
X and 16 (and, in the sites test, for every agent count 24..100): the decode of the copy equals the original instruction by
instruction except the listed fields; the walk is repeated on the copy and every stack access that was at or above the top has the
same offset from the CALLER's stack pointer, every one below has that offset minus X; the unwind data (re-read from the patched
bytes) has the new ALLOC_LARGE, every SAVE at or above the top moved by X, every other code unchanged, the GS cookie offset +X.

**Run time** (`agent_capacity.cpp`, `plan_frames`): X = `layout::frame_extra()` = `((2 * sentient_slots() - 71) * 32 + 15) & ~15`
(room for one entry per sentient slot from each of the two loops; 2272 at 24 agents, 7136 at 100). Fields are queued with `add()` in the
same all-or-nothing transaction (instruction fields as code, unwind fields as data: `VirtualProtect` read/write, checked against
their stock value first), the probe cave through `cave()`. The log line `[agent capacity] frame grow of 1403E61B0: extra N bytes, 23 fields,
probe caves 1` shows it ran. The unwind probe (`-agent-capacity-unwind-probe [n]`, env `IW7_AGENT_CAPACITY_UNWIND_PROBE`) raises
`Com_Error(ERR_DROP)` n seconds after the first call of `FUN_1403E5700` (called only from `FUN_1403E61B0`) from inside that call, so the
engine's longjmp unwinds through the grown frame and reads its unwind data and GS handler.

**Not in the formula.** Loop B's list (`FUN_1404406B0`/`E0`) is a pool of 0x8FE = 2,302 links, so its firm bound is not the sentient
count; the formula holds `slots` entries from each loop. A firm-bound X (76,096 bytes at 100 agents) would also work; the constant
is the one function `frame_extra()`.
