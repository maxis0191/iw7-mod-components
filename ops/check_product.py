"""Run declared source-only checks in a qualified dependency source workspace."""
import argparse
import concurrent.futures
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
from source_workspace import verify

def default_jobs():
    env = os.environ.get('IW7_CHECK_JOBS')
    if env:
        return max(1, int(env))
    return min(8, max(2, (os.cpu_count() or 4) // 2))

def run_checks(checks, jobs, run_one, on_start=None, on_end=None):
    """Run checks; those marked "serial": true never overlap any other check.

    Non-serial checks run first on a pool of `jobs` threads, then the serial ones one at a time.
    run_one(check) returns a row dict. Rows come back in the order of `checks`.
    on_start(check) and on_end(check, row) are called from the worker thread when a check starts and ends.
    """
    rows = [None] * len(checks)
    def run_at(i):
        check = checks[i]
        if on_start: on_start(check)
        try:
            row = run_one(check)
        except BaseException as error:  # a check that raises is a failed check, never a crash of the runner
            row = dict(id=check['id'], command=check.get('command', []), exit_code=125, seconds=0.0,
                       log=None, error='%s: %s' % (type(error).__name__, error))
        rows[i] = row
        if on_end: on_end(check, row)
    parallel = [i for i, c in enumerate(checks) if not c.get('serial')]
    serial = [i for i, c in enumerate(checks) if c.get('serial')]
    if jobs <= 1:
        for i in parallel + serial:
            run_at(i)
    else:
        if parallel:
            with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
                for future in [pool.submit(run_at, i) for i in parallel]:
                    future.result()
        for i in serial:
            run_at(i)
    return rows

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--project', required=True, type=Path)
    p.add_argument('--workspace', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--only', action='append', default=[])
    p.add_argument('--jobs', type=int, default=None,
                   help='checks at once (default: env IW7_CHECK_JOBS, else min(8, max(2, cpus/2))); checks marked "serial": true run alone')
    args = p.parse_args()
    jobs = max(1, args.jobs if args.jobs is not None else default_jobs())
    sources = verify(args.workspace)
    config = json.loads((args.project / 'checks.json').read_text(encoding='utf-8-sig'))
    if sources['product'] != config['product']:
        raise ValueError('Test product differs from source workspace')
    args.output.mkdir(parents=True, exist_ok=False)
    selected = [c for c in config['checks'] if not args.only or c['id'] in args.only]
    lock = threading.Lock()
    done = {}
    wall_started = time.monotonic()

    def write_results():
        # Called with the lock held. Rows keep the order of checks.json whatever the finishing order.
        rows = [done[c['id']] for c in selected if c['id'] in done]
        (args.output / 'results.json').write_text(json.dumps(dict(product=config['product'], revisions=sources['revisions'],
            runtime_qualified=False, jobs=jobs, wall_seconds=round(time.monotonic()-wall_started, 3), results=rows), indent=2)+'\n', encoding='utf-8')

    def run_one(check):
        command = [v.replace('{workspace}', str(args.workspace.resolve())).replace('{run}', str(args.output.resolve())) for v in check['command']]
        if command[0] == 'python': command[0] = sys.executable
        started = time.monotonic()
        log = args.output / (check['id'] + '.log')
        with log.open('wb') as stream:
            try:
                # timeout_seconds: a check that waits in turn for the machine's Build slot may need longer than 600 s.
                run = subprocess.run(command, cwd=args.workspace, stdout=stream, stderr=subprocess.STDOUT,
                                     timeout=int(check.get('timeout_seconds', 600)))
                exit_code = run.returncode
            except subprocess.TimeoutExpired:
                exit_code = 124
            except BaseException as error:
                stream.write(('runner error: %s: %s\n' % (type(error).__name__, error)).encode('utf-8', 'replace'))
                exit_code = 125
        return dict(id=check['id'], command=command, exit_code=exit_code,
                    seconds=round(time.monotonic()-started, 3), log=log.name)

    def on_start(check):
        with lock:
            print('CHECK ' + check['id'], flush=True)

    def on_end(check, row):
        with lock:
            if row.get('error'):
                log = args.output / (check['id'] + '.log')
                with log.open('ab') as stream:
                    stream.write(('runner error: %s\n' % row['error']).encode('utf-8', 'replace'))
                row['log'] = log.name
            done[check['id']] = row
            print(('PASS ' if row['exit_code'] == 0 else 'FAIL ') + check['id'], flush=True)
            write_results()

    results = run_checks(selected, jobs, run_one, on_start, on_end)
    wall = round(time.monotonic() - wall_started, 3)
    with lock:
        write_results()
    verify(args.workspace)
    # Declared but not run here: say so in the log, with the reason, instead of staying silent.
    for check in config.get('retained_checks', []):
        if not args.only:
            print('RETAINED ' + check['id'] + ': ' + check.get('reason', 'no reason recorded'), flush=True)
    if not results:
        raise ValueError('No selected checks executed')
    failed = [r['id'] for r in results if r['exit_code']]
    print(json.dumps(dict(checks=len(results), failed=failed, retained=0 if args.only else len(config.get('retained_checks', [])), runtime_qualified=False, jobs=jobs, wall_seconds=wall)))
    return 1 if failed else 0

if __name__ == '__main__':
    raise SystemExit(main())
