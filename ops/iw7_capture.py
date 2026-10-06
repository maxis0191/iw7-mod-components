"""Windows read-only process observer with a retained, verified process handle."""
import argparse
import ctypes as c
from ctypes import wintypes as w
from datetime import datetime, timezone
import json
from pathlib import Path
import socket
import sys
import time

from iw7_debugger import SCHEMA, digest, emit, local_output


class Memory(c.Structure):
    _fields_ = [("cb", w.DWORD), ("faults", w.DWORD)] + [(n, c.c_size_t) for n in
        ("peak_ws", "ws", "peak_paged", "paged", "peak_nonpaged", "nonpaged", "commit", "peak_commit", "private")]


class Performance(c.Structure):
    _fields_ = [("cb", w.DWORD)] + [(n, c.c_size_t) for n in
        ("commit", "limit", "peak", "physical_total", "physical_available", "cache", "kernel_total", "kernel_paged", "kernel_nonpaged", "page_size")] + [(n, w.DWORD) for n in ("handles", "processes", "threads")]


class IO(c.Structure):
    _fields_ = [(n, c.c_ulonglong) for n in ("reads", "writes", "other", "read_bytes", "write_bytes", "other_bytes")]


class ThreadEntry(c.Structure):
    _fields_ = [("size", w.DWORD), ("usage", w.DWORD), ("tid", w.DWORD), ("pid", w.DWORD),
                ("priority", w.LONG), ("delta", w.LONG), ("flags", w.DWORD)]


def ticks(ft):
    return (ft.dwHighDateTime << 32) | ft.dwLowDateTime


def function(dll, name, args, ret):
    fn = getattr(dll, name)
    fn.argtypes, fn.restype = args, ret
    return fn


class Observer:
    def __init__(self, pid, image, created, sha, dump_mode=False):
        if sys.platform != "win32":
            raise ValueError("Windows only")
        self.kernel = c.WinDLL("kernel32", use_last_error=True)
        self.psapi = c.WinDLL("psapi", use_last_error=True)
        self.close_handle = function(self.kernel, "CloseHandle", [w.HANDLE], w.BOOL)
        self.get_times = function(self.kernel, "GetProcessTimes", [w.HANDLE] + [c.POINTER(w.FILETIME)] * 4, w.BOOL)
        self.wait = function(self.kernel, "WaitForSingleObject", [w.HANDLE, w.DWORD], w.DWORD)
        self.memory = function(self.psapi, "GetProcessMemoryInfo", [w.HANDLE, c.POINTER(Memory), w.DWORD], w.BOOL)
        self.performance = function(self.psapi, "GetPerformanceInfo", [c.POINTER(Performance), w.DWORD], w.BOOL)
        self.io = function(self.kernel, "GetProcessIoCounters", [w.HANDLE, c.POINTER(IO)], w.BOOL)
        self.thread_times = function(self.kernel, "GetThreadTimes", [w.HANDLE] + [c.POINTER(w.FILETIME)] * 4, w.BOOL)
        self.open_thread = function(self.kernel, "OpenThread", [w.DWORD, w.BOOL, w.DWORD], w.HANDLE)
        self.snapshot = function(self.kernel, "CreateToolhelp32Snapshot", [w.DWORD, w.DWORD], w.HANDLE)
        self.thread_first = function(self.kernel, "Thread32First", [w.HANDLE, c.POINTER(ThreadEntry)], w.BOOL)
        self.thread_next = function(self.kernel, "Thread32Next", [w.HANDLE, c.POINTER(ThreadEntry)], w.BOOL)
        access = (0x410 if dump_mode else 0x1010) | 0x100000
        self.handle = function(self.kernel, "OpenProcess", [w.DWORD, w.BOOL, w.DWORD], w.HANDLE)(access, False, pid)
        self.pid = pid
        if not self.handle:
            raise c.WinError(c.get_last_error())
        try:
            buf, size = c.create_unicode_buffer(32768), w.DWORD(32768)
            query = function(self.kernel, "QueryFullProcessImageNameW", [w.HANDLE, w.DWORD, w.LPWSTR, c.POINTER(w.DWORD)], w.BOOL)
            if not query(self.handle, 0, buf, c.byref(size)):
                raise c.WinError(c.get_last_error())
            actual = Path(buf.value).resolve()
            creation, _, _ = self.times(self.get_times, self.handle)
            actual_created = datetime.fromtimestamp(creation / 10_000_000 - 11644473600, timezone.utc)
            expected = datetime.fromisoformat(created.replace("Z", "+00:00"))
            if expected.tzinfo is None or abs((expected - actual_created).total_seconds()) > .001:
                raise ValueError("Creation time mismatch; possible PID reuse")
            if actual != Path(image).resolve() or digest(actual).lower() != sha.lower():
                raise ValueError("Executable identity/hash mismatch")
            self.identity = {"pid": pid, "image": actual.name, "created_utc": actual_created.isoformat(), "sha256": sha.lower()}
        except BaseException:
            self.close()
            raise

    def times(self, fn, handle):
        values = [w.FILETIME() for _ in range(4)]
        if not fn(handle, *(c.byref(x) for x in values)):
            raise c.WinError(c.get_last_error())
        return ticks(values[0]), ticks(values[2]), ticks(values[3])

    def threads(self):
        handle = self.snapshot(4, 0)
        if handle == c.c_void_p(-1).value:
            raise c.WinError(c.get_last_error())
        result = {}
        try:
            entry = ThreadEntry(size=c.sizeof(ThreadEntry))
            ok = self.thread_first(handle, c.byref(entry))
            while ok:
                if entry.pid == self.pid:
                    th = self.open_thread(0x800, False, entry.tid)
                    if th:
                        try:
                            created, kernel, user = self.times(self.thread_times, th)
                            result[(entry.tid, created)] = (kernel + user) / 10_000_000
                        except OSError:
                            pass  # Exiting threads have no trustworthy sample.
                        finally:
                            self.close_handle(th)
                ok = self.thread_next(handle, c.byref(entry))
        finally:
            self.close_handle(handle)
        return result

    def sample(self):
        status = self.wait(self.handle, 0)
        if status == 0:
            return None
        if status != 258:
            raise c.WinError(c.get_last_error())
        mem, perf, io = Memory(), Performance(), IO()
        mem.cb, perf.cb = c.sizeof(mem), c.sizeof(perf)
        for fn, obj, extra in ((self.memory, mem, (self.handle,)), (self.performance, perf, ())):
            if not fn(*extra, c.byref(obj), c.sizeof(obj)):
                raise c.WinError(c.get_last_error())
        if not self.io(self.handle, c.byref(io)):
            raise c.WinError(c.get_last_error())
        _, kernel, user = self.times(self.get_times, self.handle)
        if not perf.physical_total or not perf.limit:
            raise ValueError("Invalid resource telemetry")
        return {"cpu_seconds": (kernel + user) / 10_000_000, "private_bytes": int(mem.private),
                "working_set": int(mem.ws), "page_faults": int(mem.faults),
                "read_bytes": int(io.read_bytes), "write_bytes": int(io.write_bytes),
                "physical_percent": 100 * (1 - perf.physical_available / perf.physical_total),
                "commit_percent": 100 * perf.commit / perf.limit}

    def close(self):
        if self.handle:
            self.close_handle(self.handle)
            self.handle = None

    def dump(self, output):
        import msvcrt
        if self.wait(self.handle, 0) != 258:
            raise ValueError("Process exited before snapshot")
        # Separate external DbgHelp avoids its single-threaded in-process restriction.
        dbghelp = c.WinDLL("dbghelp", use_last_error=True)
        write = function(dbghelp, "MiniDumpWriteDump", [w.HANDLE, w.DWORD, w.HANDLE, w.DWORD, c.c_void_p, c.c_void_p, c.c_void_p], w.BOOL)
        with output.open("xb") as f:
            file_handle = msvcrt.get_osfhandle(f.fileno())
            if not write(self.handle, self.pid, file_handle, 0x1000 | 0x800 | 0x20, None, None, None):
                raise c.WinError(c.get_last_error())


def udp_sample(port):
    start = time.perf_counter()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(.25)
        s.connect(("127.0.0.1", port))
        s.send(b"\xff\xff\xff\xffgetinfo iw7debug")
        try:
            response = s.recv(8192)
        except OSError:
            return {"udp": "unavailable", "udp_rtt_ms": None}
    if not response.startswith(b"\xff\xff\xff\xffinfoResponse\n"):
        return {"udp": "invalid", "udp_rtt_ms": None}
    text = response.split(b"\n", 1)[1].decode("ascii", errors="replace")
    parts = text.split("\\")
    fields = dict(zip(parts[1::2], parts[2::2]))
    # Allowlist only; no usernames, passwords, GUIDs, endpoint fields or hostname.
    return {"udp": "valid", "udp_rtt_ms": (time.perf_counter() - start) * 1000,
            "server": {k: fields[k] for k in ("mapname", "clients", "sv_maxclients", "sv_running", "gametype") if k in fields}}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--pid", type=int, required=True)
    p.add_argument("--image", required=True)
    p.add_argument("--created", required=True)
    p.add_argument("--sha256", required=True)
    p.add_argument("--seconds", type=int, default=30, choices=range(1, 121), metavar="1..120")
    p.add_argument("--interval-ms", type=int, default=500, choices=range(100, 5001), metavar="100..5000")
    p.add_argument("--port", type=int, default=0, choices=range(0, 65536))
    p.add_argument("--threads", action="store_true")
    p.add_argument("--snapshot", action="store_true", help="Called only by the lab-ownership guarded PowerShell adapter")
    p.add_argument("--scenario", required=True)
    p.add_argument("--output", required=True)
    args = p.parse_args()
    out = local_output(args.output)
    obs = Observer(args.pid, args.image, args.created, args.sha256, args.snapshot)
    count = 0
    try:
        if args.snapshot:
            obs.dump(out)
            emit({"schema": SCHEMA, "kind": "snapshot", "identity": obs.identity, "output": str(out), "sha256": digest(out),
                  "limits": "Live thread/stack snapshot, not a captured crash exception. Memory acquisition can perturb timing."})
            return
        with out.open("x", encoding="utf-8") as f:
            def row(obj):
                f.write(json.dumps(obj, allow_nan=False) + "\n"); f.flush()
            row({"type": "header", "schema": SCHEMA, "identity": obs.identity,
                 "scenario": args.scenario, "started_utc": datetime.now(timezone.utc).isoformat(),
                 "limits": "Read-only observer; OS CPU/I/O and loopback RTT are not engine frame durations. Existing activity is not a controlled benchmark."})
            previous, thread_before, last = obs.sample(), obs.threads() if args.threads else {}, time.perf_counter()
            deadline = last + args.seconds
            while time.perf_counter() < deadline:
                time.sleep(min(args.interval_ms / 1000, max(0, deadline - time.perf_counter())))
                start = time.perf_counter()
                current = obs.sample()
                if current is None or previous is None:
                    row({"type": "process_exit", "at_utc": datetime.now(timezone.utc).isoformat()})
                    break
                now = time.perf_counter()
                interval = now - last
                current["cpu_core_percent"] = max(0, 100 * (current["cpu_seconds"] - previous["cpu_seconds"]) / interval)
                for key in ("read_bytes", "write_bytes"):
                    current[key + "_delta"] = max(0, current[key] - previous[key])
                if args.threads:
                    thread_now = obs.threads()
                    current["thread_count"] = len(thread_now)
                    current["threads"] = [{"id": tid, "cpu_core_percent": max(0, 100 * (cpu - thread_before[(tid, created)]) / interval)}
                                          for (tid, created), cpu in thread_now.items() if (tid, created) in thread_before]
                    thread_before = thread_now
                if args.port and count % max(1, round(1000 / args.interval_ms)) == 0:
                    current.update(udp_sample(args.port))
                row({"type": "sample", "at_utc": datetime.now(timezone.utc).isoformat(),
                     "elapsed_ms": interval * 1000, "observer_cost_ms": (time.perf_counter() - start) * 1000, **current})
                previous, last, count = current, now, count + 1
            row({"type": "complete", "samples": count})
    finally:
        obs.close()
    emit({"schema": SCHEMA, "kind": "capture", "output": str(out), "samples": count})


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as exc:
        emit({"schema": SCHEMA, "kind": "error", "error": str(exc)})
        sys.exit(1)
