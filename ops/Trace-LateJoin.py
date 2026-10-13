"""Bounded, read-only dedicated telemetry. See docs/LATE-JOIN-AUDIT.md.

No injection, hooks, process suspension, commands, packet capture or memory writes.
Only anonymous slot numbers and selected numeric engine fields reach the trace.
This does not capture client prediction or prove why a packet was rejected.
"""
import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import time


GAME_TIME = 0x143C986D8
CLIENT_COUNT = 0x146B229E0
CLIENT_TABLE = 0x146B22950
SERVER_ID = 0x146B22A88
ENTITIES = 0x143D22610
# Hashes of short, unchanged instruction ranges, NOT redistributed engine bytes.
# They check the reliable fields used below; they are not a full layout proof.
LAYOUT_SIGNATURES = (
    (0x140C59438, 47, "7a62ad63270535148a0b0ad71538671ea8632a4cdace2385c1484d9019814c89"),
    (0x140C53585, 20, "0c34e6c231cf4cf290ef8f6d7ed44f6a63fe025142dac039f9efb8bf05ae177a"),
    (0x140C5941F, 6, "0658462ab771bea62f6bdc30fd112c339a02daa5e0efb73edf2b3fe25d1ce69a"),
)


def signed_delta(a, b):
    """32-bit engine counter subtraction, including rollover."""
    return ((a - b + 0x80000000) & 0xFFFFFFFF) - 0x80000000


def pointer(value):
    if value < 0x10000 or value >= 0x0000800000000000 or value % 8:
        raise ValueError("Invalid engine pointer; unsupported layout or transition")
    return value


class Fields:
    def __init__(self, read):
        self.read = read

    def value(self, address, fmt):
        return struct.unpack(fmt, self.read(address, struct.calcsize(fmt)))[0]

    def i32(self, address):
        return self.value(address, "<i")

    def u8(self, address):
        return self.value(address, "<B")

    def ptr(self, address):
        return pointer(self.value(address, "<Q"))

    def sample(self):
        before = self.i32(GAME_TIME)
        count = self.i32(CLIENT_COUNT)
        if not 1 <= count <= 18:
            raise ValueError("Dedicated not ready or unsupported client count")
        server_id = self.u8(SERVER_ID)
        slots = []
        consistent = True
        for slot in range(count):
            client = self.ptr(CLIENT_TABLE + 8 * slot)
            state = self.u8(client + 8)
            if not 0 <= state <= 5:
                raise ValueError("Unsupported client state")
            if state < 3:
                continue
            seq = self.i32(client + 0x41274)
            ack = self.i32(client + 0x41278)
            last_cmd = self.i32(client + 0x18)
            row = {
                "slot": slot, "state": state,
                "client_server_id": self.i32(client + 0x9F35C),
                "reliable_sequence": seq, "reliable_ack": ack,
                "reliable_pending": signed_delta(seq, ack),
                "message_ack": self.i32(client + 0x41280),
                "last_usercmd_time": last_cmd,
                "server_minus_last_usercmd_ms": signed_delta(before, last_cmd),
            }
            if state == 5:
                entity = self.ptr(client + 136)
                if entity != ENTITIES + slot * 1016:
                    raise ValueError("Client/entity binding changed or unsupported")
                ps = self.ptr(entity + 368)
                vector = struct.unpack("<6f", self.read(ps + 40, 24))
                if not all(math.isfinite(x) for x in vector):
                    raise ValueError("Non-finite player state")
                row.update({
                    "ps_command_time": self.i32(ps),
                    "pm_type": self.i32(ps + 4),
                    "origin": list(vector[:3]), "velocity": list(vector[3:]),
                    "gravity": self.i32(ps + 120), "speed": self.i32(ps + 124),
                })
                consistent &= self.ptr(entity + 368) == ps
            consistent &= self.u8(client + 8) == state
            consistent &= self.ptr(CLIENT_TABLE + 8 * slot) == client
            slots.append(row)
        after = self.i32(GAME_TIME)
        consistent &= before == after and count == self.i32(CLIENT_COUNT)
        consistent &= server_id == self.u8(SERVER_ID)
        return {"server_time": before, "server_time_after": after,
                "server_id": server_id, "slots": slots,
                "stable_frame_and_bindings": bool(consistent)}


def utc_datetime(text):
    result = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("Creation time must contain a timezone")
    return result.astimezone(timezone.utc)


class ProcessReader:
    def __init__(self, pid, image, created_utc, sha256):
        if os.name != "nt" or ctypes.sizeof(ctypes.c_void_p) != 8:
            raise RuntimeError("Requires 64-bit Python on Windows")
        self.handle = None
        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        definitions = {
            "OpenProcess": ([wintypes.DWORD, wintypes.BOOL, wintypes.DWORD], wintypes.HANDLE),
            "CloseHandle": ([wintypes.HANDLE], wintypes.BOOL),
            "ReadProcessMemory": ([wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p,
                                   ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)], wintypes.BOOL),
            "QueryFullProcessImageNameW": ([wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR,
                                            ctypes.POINTER(wintypes.DWORD)], wintypes.BOOL),
            "GetProcessTimes": ([wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4,
                                wintypes.BOOL),
        }
        for name, (args, result) in definitions.items():
            function = getattr(self.api, name)
            function.argtypes, function.restype = args, result
        # PROCESS_VM_READ | PROCESS_QUERY_LIMITED_INFORMATION, no write/debug rights.
        self.handle = self.api.OpenProcess(0x1010, False, pid)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            name = ctypes.create_unicode_buffer(32768)
            length = wintypes.DWORD(len(name))
            if not self.api.QueryFullProcessImageNameW(self.handle, 0, name, ctypes.byref(length)):
                raise ctypes.WinError(ctypes.get_last_error())
            expected_path = Path(image).resolve(strict=True)
            if os.path.normcase(name.value) != os.path.normcase(str(expected_path)):
                raise ValueError("Process image does not match explicit identity")
            times = [wintypes.FILETIME() for _ in range(4)]
            if not self.api.GetProcessTimes(self.handle, *(ctypes.byref(t) for t in times)):
                raise ctypes.WinError(ctypes.get_last_error())
            ticks = (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime
            created = datetime.fromtimestamp(ticks / 10_000_000 - 11644473600, timezone.utc)
            if abs((created - utc_datetime(created_utc)).total_seconds()) > 0.01:
                raise ValueError("Process creation time mismatch; possible PID reuse")
            with expected_path.open("rb") as executable:
                actual_hash = hashlib.file_digest(executable, "sha256").hexdigest()
            if actual_hash != sha256.lower():
                raise ValueError("Executable SHA-256 mismatch")
            for address, size, expected in LAYOUT_SIGNATURES:
                if hashlib.sha256(self.read(address, size)).hexdigest() != expected:
                    raise ValueError("Engine layout signature mismatch; no sampling")
            self.identity = {"pid": pid, "image": expected_path.name,
                             "created_utc": created.isoformat(), "sha256": actual_hash}
        except BaseException:
            self.close()
            raise

    def read(self, address, size):
        if not 1 <= size <= 64:
            raise ValueError("Read exceeds the bounded field limit")
        buffer = ctypes.create_string_buffer(size)
        received = ctypes.c_size_t()
        if not self.api.ReadProcessMemory(self.handle, address, buffer, size, ctypes.byref(received)):
            raise ctypes.WinError(ctypes.get_last_error())
        if received.value != size:
            raise RuntimeError("Partial process-memory read")
        return buffer.raw

    def close(self):
        if self.handle:
            self.api.CloseHandle(self.handle)
            self.handle = None


def output_path(text):
    runtime = Path(__file__).resolve().parents[1] / "runtime"
    # Resolve links and junctions before checking containment. No overwrite.
    if runtime.exists() and runtime.resolve() != runtime:
        raise ValueError("Runtime directory may not be redirected")
    candidate = Path(text).absolute().resolve()
    if not candidate.is_relative_to(runtime) or candidate == runtime:
        raise ValueError("Output must be a new file under this worktree's runtime directory")
    if candidate.suffix != ".jsonl" or candidate.exists():
        raise ValueError("Output must be a new .jsonl file")
    return candidate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--expected-image", required=True)
    parser.add_argument("--expected-created-utc", required=True)
    parser.add_argument("--expected-sha256", required=True)
    parser.add_argument("--seconds", type=int, default=30, choices=range(1, 121), metavar="1..120")
    parser.add_argument("--interval-ms", type=int, default=100, choices=range(50, 1001), metavar="50..1000")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    destination = output_path(args.output)
    reader = ProcessReader(args.pid, args.expected_image, args.expected_created_utc, args.expected_sha256)
    samples = active = unstable = 0
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        # Repeat containment after directory creation, before exclusive open.
        destination = output_path(str(destination))
        with destination.open("x", encoding="utf-8") as output:
            def emit(record):
                output.write(json.dumps(record, allow_nan=False) + "\n")
                output.flush()
            emit({"type": "header", "schema": 1, "identity": reader.identity,
                  "started_utc": datetime.now(timezone.utc).isoformat(),
                  "limits": "server-only; asynchronous reads; no packet rejection or client prediction trace"})
            start = time.monotonic()
            try:
                while time.monotonic() - start < args.seconds:
                    sample = Fields(reader.read).sample()
                    samples += 1
                    active += sum(row["state"] == 5 for row in sample["slots"])
                    unstable += not sample["stable_frame_and_bindings"]
                    emit({"type": "sample", "elapsed_ms": round((time.monotonic() - start) * 1000), **sample})
                    time.sleep(args.interval_ms / 1000)
            except BaseException as error:
                emit({"type": "aborted", "error_type": type(error).__name__, "message": str(error)})
                raise
            emit({"type": "complete", "samples": samples, "active_slot_samples": active,
                  "unstable_samples": unstable, "gameplay_pass": None})
    finally:
        reader.close()
    print(json.dumps({"samples": samples, "active_slot_samples": active,
                      "unstable_samples": unstable, "output": str(destination)}))


if __name__ == "__main__":
    main()
