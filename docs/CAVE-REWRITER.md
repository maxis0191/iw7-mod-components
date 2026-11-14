# Cave rewriter: grow an instruction by moving it to a code cave

Status (14 Nov 2026): built and proven in the headless game, see "Proof" below. Not used for the A1 change set yet.

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
| the window contains a relative `jmp`, `jcc`, `call`, `loop`, `jrcxz`, `xbegin` | its displacement is relative to the old address; copied to the cave it jumps somewhere else. A `call`/`jmp` with a rip-relative MEMORY operand (`call [rip+x]`) is allowed: it becomes a fixup |
| any byte of the window after its first is the target of a branch, call or data reference from anywhere in the image | the window after the first byte becomes `jmp` operand bytes and `int3`: a jump into it crashes. Checked by (1) the engine database's `refs` and `calls` tables over the whole range, (2) a byte scan of every executable section for rel32 and rel8 branches landing in it, (3) a scan of all sections for 8-byte absolute pointers and 4-byte image-relative values (jump tables) equal to an interior instruction start |
| two requests ask for the same instruction | ambiguous |
| a request is not at an instruction boundary of its window | the decode disagrees with the request |
| `disp` kind: the instruction has no single ModRM memory operand, has a register operand (`mod 11`), is rip-relative (its displacement is an address, not a table offset) or is EVEX (its 8-bit displacement is scaled) | the re-encoding is not defined for these |
| `bytes` kind: new bytes do not decode completely, or contain a rip-relative operand or a relative branch | they would be moved to another address with no fixup for them |
| a rip-relative target is more than 2 GB from the cave | the 32-bit field cannot reach it (checked in the self-check, and again at run time) |
| the self-check below finds any difference | an encoder bug must never reach the game |

Merging: requests whose windows overlap are merged into one cave (the window runs from the first start to cover the last
changed instruction, at least 5 bytes); the rules apply to the merged window.

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
- Exception and unwind data: the cave has no `RUNTIME_FUNCTION` entry. A C++ exception or a stack walk that crosses the cave
  cannot unwind through it. A window must not contain code that can throw (calls into callees are fine only because the
  callee's own unwind data covers its frames, and the walker then stops in the cave). The crash reader shows an
  access/illegal-instruction fault in a cave correctly (it reports the cave address), which is how the proof below works.
- Calls inside a window push a return address into the cave: code that inspects its own return address would see it.
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

## Proof (14 Nov 2026, components `585b04f`, one lab client, headless, 24 agents)

Four zero-change caves (`ops/engine/caves/proof-zero-change.*`): each instruction is re-encoded from disp8 to disp32 with the
SAME displacement (`force32`) and moved to a cave. Windows (stock bytes -> cave bytes):

| Window | Function | Stock | Cave |
| --- | --- | --- | --- |
| `140ADABFC` (6) | FUN_140ADABD0 (A.20) | `8b440a1485c0` mov eax,[rdx+rcx+0x14]; test eax,eax | `8b840a1400000085c0` |
| `140ADBA7E` (7) | FUN_140ADB8E0 (A.23) | `2b4c1a1483e964` sub ecx,[rdx+rbx+0x14]; sub ecx,0x64 | `2b8c1a1400000083e964` |
| `140ADC274` (6) | FUN_140ADC1E0 (A.25) | `8b441a1485c0`-class window | not reached, see below |
| `140AE2029` (7) | FUN_140AE2000 (A.29) | mov eax,[rbx+rdx+0x24] + next instruction | disp32 0x24 |

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

