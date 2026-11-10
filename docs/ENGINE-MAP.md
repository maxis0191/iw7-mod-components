# Engine map

## What it is

`ops/engine-map/iw7_engine_map.py` builds a SQLite map of the game executable's code.
The map lists every function, the calls between them, the strings they use and the names we know.
Function boundaries come from the x64 exception directory.
An address from a sampling profiler or a crash then resolves to a function name.

The inputs are three raw section files kept on the machine: the code bytes, the read-only data bytes and the exception directory.
They are named `unpacked-text.bin`, `unpacked-rdata.bin` and `unpacked-pdata.bin` and sit in one folder, the reference root.
These files and the SQLite map are machine-local. They are never committed.
The tool uses `capstone` to decode the code.

The tool assumes the image base 0x140000000, the code section at 0x140001000 and the read-only data at 0x141435000.

## Build

```
python -B ops/engine-map/iw7_engine_map.py build --db <db> --reference-root <reference root> --symbols <symbols.hpp>
```

Optional inputs:

- `--names <list.csv>` (repeatable): rows of `name,address`. Other rows are ignored.
- `--native-src <folder>`: every `0x14xxxxxxx` constant in the `.cpp` and `.hpp` files there becomes a `hook:` name.
- `--names-file <names.json>`: the names file described under "Naming a function".
- `--workers <n>`: scan processes. The scan is serial for small inputs.

The real build takes about 5 seconds.
A second build from the same inputs gives identical tables.
The old database file is replaced.

## Numbers of the real map on 2026-11-10

| Item | Value |
| --- | --- |
| Functions | 50,095 |
| Fragments (a function can have several) | 81,408 |
| Leaf functions found without directory data | 12,030 |
| Gaps (code that is neither a function nor padding) | 17,330 gaps, 321,914 bytes |
| Covered bytes | 20,661,583 of 21,135,360 code bytes |
| Direct calls | 209,302 |
| Tail calls | 68,706 |
| References (rip-relative) | 218,186 |
| Strings | 16,317 |
| Names | 588, of which 398 sit at a function start |
| Names inside a function / not in code | 65 / 125 |
| Decode failures | 34,539 |
| Partial functions | 7,612 |
| Directory entries in other sections | 6 |

The rest of the code bytes is padding (151,863 bytes).
`selftest` passes on this map.
10,473 functions have no direct caller.

## Commands

All commands take `--db <db>` and `--json`. `name` ignores `--json`.
An address can be `0x140C04580`, `140C04580`, `+0xC04580` (offset from the image base), `sub_140C04580` or a known name.

`at` resolves addresses to functions.

```
$ at AllocThread
140C04580  AllocThread  function start  size 44, 1 fragment(s)
```

`callers FUNC` lists the functions that call FUNC. `callees FUNC` lists what FUNC calls.
`--depth N` follows the chain, `--max N` cuts the output. A tail call shows as `(tail)`.

```
$ callers Sys_Milliseconds --max 5
sub_1405AED60  x12
sub_1409D61C0  x7
sub_140C595D0  x6
sub_1405AE810  x5
sub_1409CAB20  x5
... 444 more
```

`find-string TEXT` finds strings that contain TEXT (any case) and the functions that use them. `--regex` takes a pattern.

```
$ find-string com_maxfps --max 3
141509AA0  "com_maxfps"
    sub_140BB7F90  at 140BB8063
    sub_140BC3CB0  at 140BC3CFB
```

`strings FUNC` lists the strings one function refers to.

```
$ strings sub_140BB7F90
140BB7F98  "[MP] Pause the client"
140BB7FA4  "cl_paused"
140BB7FC8  "[MP] Pause the server"
140BB7FD7  "sv_paused"
...
```

`refs ADDRESS` lists the code that refers to an address, by reference or by call or jump.

```
$ refs Sys_Milliseconds --max 3
sub_14009B6A0  at 14009B7CF  (call)
sub_14009B7F0  at 14009B930  (call)
sub_14009E780  at 14009E7AA  (call)
```

`names --like TEXT` lists the known names that contain TEXT.

```
$ names --like AllocThread
140C04580  AllocThread                                  symbols.hpp
```

`disasm FUNC --reference-root <reference root>` prints the code of one function with the names of its call targets and strings. `--max N` sets the line limit (120 by default).

```
$ disasm AllocThread --max 8
AllocThread:
  140C04580  push     rbx
  140C04582  sub      rsp, 0x20
  140C04586  mov      ebx, ecx
  140C04588  lea      rcx, [rsp + 0x30]
  140C0458D  call     0x140c04650  ; AllocVariable
  ... cut at 8 lines
```

`stats` prints the build numbers, the 20 largest functions and the 20 most called functions.

```
$ stats | head -4
base               5368709120
calls              209302
covered_bytes      20661583
decode_failures    34539
```

`selftest` checks the map: covered bytes plus padding plus gaps equal the code size, fragments do not overlap, every fragment has a function.
It exits with 1 if a check fails.

```
$ selftest
direct calls 209302: 208366 to a function start, 42 inside a function, 894 outside mapped functions
names 588: 398 at a function start, 65 inside a function, 125 not in code
selftest passed
```

`name` and `build` are described in the sections above and below.

## Joining with a profiler

`at --stdin` reads one sample per line: `address [count]`. The count defaults to 1. A comma also separates the fields.
It adds the counts per function and prints the table sorted by count, with the share of the total.
`--top N` limits the rows (40 by default).

```
$ printf '0x140C04584 120\n140BB8063 30\n0x140000010 5\n' | at --stdin
     120   77.4%  AllocThread
      30   19.4%  sub_140BB7F90
       5    3.2%  (not in a mapped function)
```

An address that is outside every function is counted under `(not in a mapped function)`.

## Naming a function

```
name <address> <name> --source <who or why> --names-file <names.json>
```

The command writes the name to the names file and to the database.
It refuses a name that is already used at another address. `--replace` moves it.

The names file is a small JSON file and can be committed:

```
{
 "schema": "iw7.engine-map-names/1",
 "names": [
  {"address": "140C04580", "name": "AllocThread", "source": "profiler"}
 ]
}
```

Pass the same file with `--names-file` at the next `build`, so the names survive a rebuild.
The SQLite database is never committed.

When an address has several names, `symbols.hpp` wins, then names from the names file, then names from lists and hook constants.
A function without a name is `sub_<HEX>`. An address inside a named function shows as `name+0xOFFSET`.

## What it cannot know

- Calls through registers and tables are not in the map. A function that is only reached that way shows no caller.
- Code and data in sections that are not in the inputs are not covered. A reference to such an address is recorded as `data`, and a directory entry for such code is only counted.
- About 7,600 functions are only partly decoded, because bytes inside their range do not decode. Their calls and strings after such a byte may be missing.
- A leaf function has no directory entry. It is found only when some code calls or jumps to it directly. Other leaf functions stay in a gap.
- Names exist only for what the listed sources name. Most functions are `sub_<HEX>`.
- A string is recorded only when it is at least 4 printable ASCII characters in the read-only data and some code refers to it with a rip-relative address.
