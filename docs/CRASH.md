# Crash stack

## What it is

`ops/engine-map/iw7_crash.py` reads the crash dump of a game client or server.
It prints the exception, where it happened, the registers and a list of return addresses with function names.
An agent that crashed the game while developing a mod can see where it crashed.

The function names come from the engine map (see `docs/ENGINE-MAP.md`).
Without a map the tool still names modules and offsets.
The tool reads the dump. It does not start the game and it does not change any file.

## The command

```
python -B ops/engine-map/iw7_crash.py report DUMP [--map MAP.sqlite] [--reference-root DIR] [--all-threads] [--json] [--max-frames N]
```

- `DUMP` is a `.dmp` file, or a `.zip` that holds exactly one `.dmp`. Other files in the zip, such as `info.txt`, are ignored.
- `--map` is the engine map. It names addresses in the game image.
- `--reference-root` is the folder with `unpacked-text.bin`, the same folder the map was built from. It lets the tool check every return address against the real code bytes. It needs `capstone`.
- `--all-threads` also prints every other thread: where it was, and its first 5 return addresses.
- `--json` prints the same content as JSON. The schema name is `iw7.crash-stack/1`.
- `--max-frames N` stops after N entries for the crashing thread. The default is 40. The summary line uses only what was kept.

Exit code 0 means a report was printed.
Exit code 2 means the input was unusable: a truncated file, a file that is not a minidump, a zip without exactly one dump, a missing map.
The message goes to stderr and starts with `error:`.

## Where the game writes dumps

The client and the dedicated server write a zip in the `minidumps` folder inside the game folder: `<game folder>/minidumps/*.zip`.
The zip holds `crash.dmp` and an `info.txt` with the version, the exception and the address.
The other tools of this repository look in the same place (`ops/iw7_watch.py`, `ops/agent-capacity/Watch-Server.ps1`, `ops/Run-CollisionProbe.ps1`).
`ops/iw7_debugger.py dump` reads the same zips and prints the module list and the exception.

## How to read the output

1. Exception. The code in hex and its usual name when the tool knows it:
   access violation (with read, write or execute and the address that was touched), stack overflow, breakpoint, fail-fast and C++ exception.
   Other codes are shown as hex only. Then the crashing thread id and the address where it happened.
2. Location. If the address is in the game code, the tool prints the function name and the offset from the engine map, for example `sub_140449450+0x4A`.
   If a function has a known name, that name is used.
   An address in the game code but in no mapped function is shown as `game+0x<offset from the image base>`.
   Any other address is shown as `module+0x<offset>` from the module list of the dump, or `not in any module`.
3. Registers. `rip`, `rsp`, `rbp` and the general registers of the crashing thread, from the context record of the exception.
4. Stack. A list of return addresses. Each line has the offset from `rsp`, the name, and a status.
5. Summary. One line for a log: `crash <exception> at <place>, called from <first verified entry>, <second verified entry>`.

A dump with no exception record is a manual dump.
The tool then prints every thread, as with `--all-threads`, and the summary says there was no exception record.

## The stack and its two kinds of entry

The tool does not unwind the stack.
It scans the stack of the crashing thread from `rsp` upward, 8 bytes at a time, and keeps a value only when it could be a return address.

- `verified call`. The value is in the game code, and a call instruction ends exactly at that address.
  With `--reference-root` the tool decodes the bytes before the value (2 to 7 bytes) and needs exactly one `call` instruction. This covers `call rel32`, `call [rip+x]` and `call reg`, shown as `direct` or `indirect`.
  With only `--map` the tool looks for a direct call in the map's call table at the address minus 5. Indirect calls cannot be checked then, and the output says so.
  A game-code value that is not after a call is dropped.
- `unverified`. The value is inside another module of the dump, for example a system DLL or the mod's own executable.
  The tool cannot check it. At most one entry per module is kept in a row.
  If the dump has the memory protection list, values in memory that is not executable are dropped.

The list can contain stale entries.
A function call leaves its return address on the stack. When the function returns, the address stays there until something overwrites it.
So the scan can show a call that finished long ago.
The first verified entries after the crash point are the most reliable. Entries far from `rsp` are less reliable.
Without `--map` and `--reference-root` nothing in the game image can be verified. All values in modules then show as `unverified`.

## A fast-fail (exit code 0xC0000409) and the lab switch

Exit code `0xC0000409` is `int 0x29` (`CD 29`): the compiler's stack-cookie failure (`__report_gsfailure`, reached by `jmp` from `__security_check_cookie`), or the CRT's abort and watson paths.
A fast-fail bypasses the crash handler, so the process leaves no dump (run h5 of 14 Nov 2026 is the example).
In a lab build (`-paris-debugger` and `-paris-isolated-lab`) with `-agent-capacity`, the component patches the five confirmed `int 0x29` of the CRT (`__report_gsfailure`, `__report_securityfailure`, `__scrt_fastfail`, `abort`, `_invoke_watson`) to `ud2` at start and prints `[agent capacity] fast-fail sites patched to ud2: 5`.
The failure then reports as an illegal instruction (`0xC000001D`) with the stack intact.
Read it as follows: the crashing frame is `__report_gsfailure` (or another CRT function above); the first verified entry of the return list below it is the function whose stack cookie check failed, that is the function whose stack buffer was overrun. Disassemble that function: its loops and copies that write into its `sub rsp, N` frame are the candidates.
The sites in the protector span (`0x14B...`, `0x14C...`) and two hits that are data bytes are not patched (their instruction boundary is not known).

## What it cannot do

- No full unwinding with the unwind data of each function. A real frame chain may differ from this list.
- No local variables, arguments or source lines.
- A frame inside the mod's own code is only `module+offset`, unless symbols are loaded elsewhere and the offset is looked up by hand.
- A return address that follows a call into code outside the engine map is dropped or shown as unverified.
- The tool trusts the engine map for the game code. A map from another game build names functions wrongly.
  The game image itself does not change between client builds, but check the build when a name looks wrong.
- It reports where the game stopped. The cause can lie earlier, for example in memory that an earlier call damaged.
