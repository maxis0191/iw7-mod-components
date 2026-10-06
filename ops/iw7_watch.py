"""Live IW7 incident stream: verified processes, logs, simulation ticks and presents.

Alerts include coverage gaps. Trends/slow scopes are hypotheses, not automatic
leak/loop diagnoses. This observer never writes into or stops a game process.
"""
import argparse
from collections import deque
import csv
from datetime import datetime, timezone
import io
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import zipfile

from iw7_capture import Observer, udp_sample
from iw7_debugger import SCHEMA, RULES, digest, dump_report, local_output, scrub


class Tail:
    def __init__(self, path):
        self.path, self.offset, self.pending = Path(path), 0, b""

    def lines(self):
        if not self.path.exists():
            return []
        size = self.path.stat().st_size
        if size < self.offset:
            raise ValueError(f"Evidence file truncated during watch: {self.path.name}")
        with self.path.open("rb") as f:
            f.seek(self.offset); data = f.read(1024 * 1024); self.offset = f.tell()
        joined = self.pending + data
        chunks = joined.split(b"\n"); self.pending = chunks.pop()
        if len(self.pending) > 1024 * 1024:
            raise ValueError("Oversized live evidence line")
        return [x.decode("utf-8-sig", errors="replace").rstrip("\r") for x in chunks]


class Detector:
    def __init__(self, frame_budget_ms=33.34, expected_tps=20, warmup=30):
        self.frame_budget, self.expected_tps, self.warmup = frame_budget_ms, expected_tps, warmup
        self.memory = deque()
        self.cpu_high = 0
        self.tick_low = 0
        self.last_alert = {}
        self.server_idle = False
        self.phase = None

    def alert(self, code, now, evidence, confidence="symptom", interval=10):
        if now - self.last_alert.get(code, -100000) < interval:
            return []
        self.last_alert[code] = now
        return [{"type": "alert", "code": code, "confidence": confidence, "evidence": evidence,
                 "elapsed_seconds": now, "causality": "not established"}]

    def sample(self, row, now):
        result = []
        server = row.get('server', {})
        self.server_idle = server.get('clients') == '0'
        phase = (server.get('mapname'), self.server_idle)
        if phase != self.phase or now < self.warmup:
            self.memory.clear()
            self.tick_low = 0
        self.phase = phase
        if row["physical_percent"] > 80 or row["commit_percent"] > 85:
            result += self.alert("resource.pressure", now, {k: row[k] for k in ("physical_percent", "commit_percent")})
        self.cpu_high = self.cpu_high + 1 if row.get("cpu_core_percent", 0) > 90 else 0
        if self.cpu_high >= 5 and now >= self.warmup:
            result += self.alert("cpu.sustained_usage", now, {"cpu_core_percent": row["cpu_core_percent"], "meaning": "Busy cores can be normal; inspect per-thread stacks and the workload."})
        self.memory.append((now, row["private_bytes"]))
        while self.memory and now - self.memory[0][0] > 60:
            self.memory.popleft()
        if len(self.memory) >= 20 and now - self.memory[0][0] >= 25 and now >= self.warmup:
            count = len(self.memory); xs = [x for x, y in self.memory]; ys = [y for x, y in self.memory]
            mx, my = sum(xs) / count, sum(ys) / count
            denom = sum((x - mx) ** 2 for x in xs)
            slope = sum((x - mx) * (y - my) for x, y in self.memory) / denom if denom else 0
            growth = ys[-1] - ys[0]
            if slope * 60 > 32 * 1024 * 1024 and growth > 16 * 1024 * 1024:
                result += self.alert("memory.growth_candidate", now, {"private_bytes_per_minute": slope * 60, "window_seconds": xs[-1] - xs[0],
                                     "growth_bytes": growth, "meaning": "Allocation trend, not proof of a leak. Compare retained post-round/post-map baselines."}, "hypothesis", 30)
        return result

    def native(self, row, now):
        if row.get("type") == "server_ticks":
            if row.get("resets") or self.server_idle or now < self.warmup or row.get("game_time_ms", -1) < 0:
                self.tick_low = 0; return []
            self.tick_low = self.tick_low + 1 if row.get("hz", 0) < self.expected_tps * .7 else 0
            if self.tick_low >= 3:
                return self.alert("server.simulation_cadence", now, {"hz": row["hz"], "expected_tps": self.expected_tps,
                                  "meaning": "GSC frame witness; transitions, VM starvation and engine stalls need correlation."})
        elif row.get("type") == "timing" and row.get("max_us", 0) > self.frame_budget * 1000:
            return self.alert(f"scope.slow.{row.get('category')}.{row.get('id')}", now,
                              {"category": row.get("category"), "id": row.get("id"), "max_us": row["max_us"],
                               "meaning": "Inclusive wall time. Waits and nested calls are included; this is not proof of an abnormal loop."})
        elif row.get('type') == 'render_window' and row.get('max_interval_ms', 0) > self.frame_budget * 2:
            return self.alert('render.callback_spike', now, {k: row.get(k) for k in ('swapchain_slot', 'callback_rate_fps', 'max_interval_ms', 'meaning')})
        elif row.get('type') == 'gpu_budget' and row.get('hresult') == 0 and row.get('budget_bytes', 0) > 0 and row.get('usage_bytes', 0) > row['budget_bytes'] * .9:
            return self.alert('gpu.process_budget_pressure', now, {k: row[k] for k in ('usage_bytes', 'budget_bytes', 'meaning')})
        return []

    def presents(self, frames, now):
        positive = [x for x in frames if x > 0 and math.isfinite(x)]
        if positive and max(positive) > self.frame_budget * 2:
            return self.alert("render.frame_spike", now, {"frames": len(positive), "max_frame_ms": max(positive),
                              "budget_ms": self.frame_budget, "instantaneous_fps_at_spike": 1000 / max(positive),
                              "meaning": "PresentMon presentation interval; loading/minimization are separate phases."})
        return []


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--targets", required=True, help="Local JSON array with name,pid,image,created_utc,sha256,stdout,stderr")
    p.add_argument("--seconds", type=int, default=60, choices=range(1, 601), metavar="1..600")
    p.add_argument("--output", required=True)
    p.add_argument("--present-csv")
    p.add_argument("--frame-budget-ms", type=float, default=33.34)
    p.add_argument("--expected-tps", type=float, default=20)
    p.add_argument("--warmup-seconds", type=int, default=30)
    p.add_argument("--port", type=int, default=0)
    args = p.parse_args()
    if not math.isfinite(args.frame_budget_ms) or args.frame_budget_ms <= 0 or not 0 < args.expected_tps <= 1000:
        raise ValueError("Invalid anomaly policy")
    target_rows = json.loads(Path(args.targets).read_text(encoding="utf-8-sig"))
    if not isinstance(target_rows, list) or not 1 <= len(target_rows) <= 3:
        raise ValueError("Expected 1..3 exact target identities")
    targets = []
    destination = local_output(args.output)
    try:
        for record in target_rows:
            observer = Observer(record["pid"], record["image"], record["created_utc"], record["sha256"])
            targets.append({"record": record, "observer": observer, "before": observer.sample(), "threads": observer.threads(),
                            "detector": Detector(args.frame_budget_ms, args.expected_tps, args.warmup_seconds),
                            "logs": [Tail(record[k]) for k in ("stdout", "stderr") if record.get(k)],
                            "log_context_remaining": {},
                            "native": {}, "last_native": 0, "native_seen": False, "dumps": set()})
        present = Tail(args.present_csv) if args.present_csv else None
        columns = None
        with destination.open("x", encoding="utf-8") as out:
            def write(row):
                row.setdefault("at_utc", datetime.now(timezone.utc).isoformat())
                out.write(json.dumps(row, allow_nan=False) + "\n"); out.flush()
                if row.get("type") in ("alert", "coverage", "complete"):
                    print(json.dumps(row), flush=True)
            write({"type": "header", "schema": SCHEMA, "scenario": "live supervised laboratory", "identities": [t["observer"].identity for t in targets],
                   "policy": {"frame_budget_ms": args.frame_budget_ms, "expected_tps": args.expected_tps, "warmup_seconds": args.warmup_seconds},
                   "limits": "Explicit sensor coverage; arbitrary gameplay bugs, every GSC bytecode loop and GPU allocations are not fully observable."})
            start = last = time.monotonic(); samples = 0; all_exit_time = None
            smi = shutil.which("nvidia-smi")
            if not present: write({"type": "coverage", "sensor": "displayed_fps", "status": "unavailable", "reason": "No PresentMon CSV; never infer displayed FPS from CPU callbacks."})
            if not smi: write({"type": "coverage", "sensor": "gpu_device", "status": "unavailable"})
            while time.monotonic() - start < args.seconds:
                now = time.monotonic(); elapsed = now - start; interval = max(.001, now - last)
                all_exited = True
                for target in targets:
                    rec = target["record"]; name = rec["name"]; obs = target["observer"]; detector = target["detector"]
                    current = obs.sample()
                    if current is None:
                        for event in detector.alert("process.exit", elapsed, {"identity": obs.identity}): write({"target": name, **event})
                    else:
                        all_exited = False
                        before = target["before"]
                        current["cpu_core_percent"] = max(0, 100 * (current["cpu_seconds"] - before["cpu_seconds"]) / interval)
                        thread_now = obs.threads()
                        current["thread_count"] = len(thread_now)
                        current["threads"] = [{"id": tid, "cpu_core_percent": max(0, 100 * (cpu - target["threads"][(tid, created)]) / interval)}
                                              for (tid, created), cpu in thread_now.items() if (tid, created) in target["threads"]]
                        for key in ("read_bytes", "write_bytes"):
                            current[key + "_delta"] = max(0, current[key] - before[key])
                        if args.port and name == "Server": current.update(udp_sample(args.port))
                        write({"type": "sample", "target": name, "elapsed_seconds": elapsed, **current})
                        for event in detector.sample(current, elapsed): write({"target": name, **event})
                        target["before"], target["threads"] = current, thread_now
                    for tail in target["logs"]:
                        for line in tail.lines():
                            if target['log_context_remaining'].get(str(tail.path), 0):
                                write({'type': 'log_context', 'target': name, 'file': tail.path.name, 'text': scrub(line)})
                                target['log_context_remaining'][str(tail.path)] -= 1
                            for code, severity, pattern, action in RULES:
                                if re.search(pattern, line, re.I):
                                    target['log_context_remaining'][str(tail.path)] = 12 if severity in ('error', 'fatal') else 0
                                    write({"type": "alert", "target": name, "code": code, "severity": severity, "text": scrub(line), "file": tail.path.name,
                                           "next_action": action, "causality": "unproven"}); break
                    root = Path(rec["image"]).parent
                    created_epoch = datetime.fromisoformat(rec["created_utc"].replace("Z", "+00:00")).timestamp()
                    for path in root.glob(f"iw7-debugger-{rec['pid']}-*.jsonl"):
                        if path.stat().st_mtime >= created_epoch:
                            target["native"].setdefault(str(path), Tail(path))
                    for tail in target["native"].values():
                        for line in tail.lines():
                            row = json.loads(line); target["last_native"] = elapsed; target["native_seen"] = True
                            write({"target": name, **row})
                            if row.get('type') == 'render_window': target['last_render'] = elapsed
                            for event in detector.native(row, elapsed): write({"target": name, **event})
                    if name == 'Client' and elapsed > 15 and elapsed - target.get('last_render', 0) > 5:
                        for event in detector.alert('coverage.render_gap', elapsed, {'meaning': 'No fresh engine render callback windows; loading, stall or absent probe.'}): write({'target': name, **event})
                    if elapsed > 15 and elapsed - target["last_native"] > 5:
                        for event in detector.alert("coverage.native_gap", elapsed, {"seen": target["native_seen"], "age_seconds": elapsed - target["last_native"], "meaning": "Loading, stall, expired profiler or missing instrumentation; investigate rather than report clean."}): write({"target": name, **event})
                    for path in (root / "minidumps").glob("*.zip"):
                        if path.stat().st_mtime >= created_epoch and str(path) not in target["dumps"]:
                            try:
                                report = dump_report(path)
                            except (ValueError, OSError, zipfile.BadZipFile):
                                continue  # A crash ZIP can still be in construction.
                            target["dumps"].add(str(path))
                            write({"type": "alert", "target": name, "code": "crash.new_dump", "file": path.name, "report": report})
                if present:
                    frames = {}
                    for line in present.lines():
                        values = next(csv.reader([line]))
                        if columns is None:
                            columns = values
                            if "MsBetweenPresents" not in columns or "ProcessID" not in columns:
                                write({"type": "coverage", "sensor": "displayed_fps", "status": "unsupported_csv_schema"}); present = None; break
                            continue
                        if len(values) != len(columns): continue
                        row = dict(zip(columns, values))
                        try: process_id = int(row["ProcessID"])
                        except ValueError: continue
                        if process_id not in [t["record"]["pid"] for t in targets]: continue
                        try: ms = float(row["MsBetweenPresents"])
                        except ValueError: continue
                        if math.isfinite(ms) and ms > 0:
                            frames.setdefault((process_id, row.get('SwapChainAddress', 'unknown')), []).append(ms)
                    if frames:
                        for (process_id, swapchain), intervals in frames.items():
                            target = next(t for t in targets if t['record']['pid'] == process_id)
                            write({"type": "present_window", "target": target['record']['name'], 'swapchain': swapchain, "frames": len(intervals), "mean_ms": sum(intervals) / len(intervals), "max_ms": max(intervals), "present_rate_fps": len(intervals) * 1000 / sum(intervals)})
                            for event in target["detector"].presents(intervals, elapsed): write({'target': target['record']['name'], 'swapchain': swapchain, **event})
                    elif elapsed > 15:
                        for event in targets[-1]["detector"].alert("coverage.present_gap", elapsed, {"meaning": "No fresh presentations; missing access, loading, occlusion or collection failure."}): write(event)
                if smi and samples % 5 == 0:
                    try:
                        result = subprocess.run([smi, "--query-gpu=memory.used,utilization.gpu,temperature.gpu", "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=3)
                        write({"type": "gpu", "status": "valid" if result.returncode == 0 else "unavailable", "values": result.stdout.strip(), "units": "MiB, percent, Celsius", "scope": "whole device, shared with other programs"})
                    except subprocess.TimeoutExpired:
                        write({"type": "coverage", "sensor": "gpu_device", "status": "timeout"})
                if all_exited:
                    if all_exit_time is None: all_exit_time = now
                    if now - all_exit_time >= 5: break  # Drain final logs/crash ZIPs.
                else: all_exit_time = None
                if out.tell() > 128 * 1024 * 1024: write({"type": "coverage", "sensor": "all", "status": "size_limit"}); break
                samples += 1; last = now
                time.sleep(max(.05, 1 - (time.monotonic() - now)))
            write({"type": "complete", "samples": samples, "gameplay_acceptance": None, "meaning": "No guarantee that uninstrumented gameplay defects were absent."})
    finally:
        for target in targets: target["observer"].close()


if __name__ == "__main__":
    try: main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired) as exc:
        print(json.dumps({"schema": SCHEMA, "type": "aborted", "error": str(exc)}), flush=True)
        sys.exit(1)
