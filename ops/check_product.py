"""Run declared source-only checks in a qualified dependency source workspace."""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import sys
import time
from source_workspace import verify

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--project', required=True, type=Path)
    p.add_argument('--workspace', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--only', action='append', default=[])
    args = p.parse_args()
    sources = verify(args.workspace)
    config = json.loads((args.project / 'checks.json').read_text(encoding='utf-8-sig'))
    if sources['product'] != config['product']:
        raise ValueError('Test product differs from source workspace')
    args.output.mkdir(parents=True, exist_ok=False)
    results = []
    for check in config['checks']:
        if args.only and check['id'] not in args.only:
            continue
        command = [v.replace('{workspace}', str(args.workspace.resolve())).replace('{run}', str(args.output.resolve())) for v in check['command']]
        if command[0] == 'python': command[0] = sys.executable
        started = time.monotonic()
        log = args.output / (check['id'] + '.log')
        print('CHECK ' + check['id'], flush=True)
        with log.open('wb') as stream:
            try:
                # timeout_seconds: a check that waits in turn for the machine's Build slot may need longer than 600 s.
                run = subprocess.run(command, cwd=args.workspace, stdout=stream, stderr=subprocess.STDOUT,
                                     timeout=int(check.get('timeout_seconds', 600)))
                exit_code = run.returncode
            except subprocess.TimeoutExpired:
                exit_code = 124
        row = dict(id=check['id'], command=command, exit_code=exit_code,
                   seconds=round(time.monotonic()-started, 3), log=log.name)
        results.append(row)
        print(('PASS ' if exit_code == 0 else 'FAIL ') + check['id'], flush=True)
        (args.output / 'results.json').write_text(json.dumps(dict(product=config['product'], revisions=sources['revisions'],
            runtime_qualified=False, results=results), indent=2)+'\n', encoding='utf-8')
    verify(args.workspace)
    if not results:
        raise ValueError('No selected checks executed')
    failed = [r['id'] for r in results if r['exit_code']]
    print(json.dumps(dict(checks=len(results), failed=failed, runtime_qualified=False)))
    return 1 if failed else 0

if __name__ == '__main__':
    raise SystemExit(main())
