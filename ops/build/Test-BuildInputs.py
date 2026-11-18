#!/usr/bin/env python3
"""No-game check: every file a build entry point reads from the prepared workspace is in the workspace.

A build runs from a prepared workspace (bootstrap.ps1 output): only what product.json exports is there. A build that
needs a file that is not exported fails halfway (the production native took 8 attempts on 18 Nov 2026 for that). This
scans the build entry points and the scripts they dot-source or start (references written as $PSScriptRoot/<path> or
$repo/<path>), resolves each path, and fails when one is missing.

    python -B ops/build/Test-BuildInputs.py <root>        root = a prepared workspace (source-workspace.json lists its
                                                          files) or a checkout (its files on disk and product.json exports)
Exit 0 all present, 1 something missing (listed), 2 bad use.
"""
import json
import os
import posixpath
import re
import sys

ENTRIES = ['ops/Build-Voice.ps1', 'ops/Build-StandardClient.ps1']
REF = re.compile(r'\$(?:PSScriptRoot|\{PSScriptRoot\}|repo|\{repo\})[/\\]+((?:\.\.[/\\]+)*[A-Za-z0-9_.\-]+(?:[/\\][A-Za-z0-9_.\-]+)*\.(?:ps1|py|json|lua|cpp|hpp|inc|gsc|txt|csv))')


def available(root):
    wm = os.path.join(root, 'source-workspace.json')
    if os.path.isfile(wm):
        with open(wm, encoding='utf-8-sig') as f:
            return {x['path'] for x in json.load(f)['files']}, 'workspace'
    out = set()
    pj = os.path.join(root, 'product.json')
    if os.path.isfile(pj):
        with open(pj, encoding='utf-8-sig') as f:
            out = set(json.load(f).get('exports', []))
    return out, 'exports'


def scan(root, have, mode):
    missing = []
    seen = set()
    todo = [e for e in ENTRIES if os.path.isfile(os.path.join(root, e))]
    while todo:
        rel = todo.pop()
        if rel in seen:
            continue
        seen.add(rel)
        with open(os.path.join(root, rel), encoding='utf-8-sig', errors='replace') as f:
            text = f.read()
        folder = posixpath.dirname(rel)
        for m in REF.finditer(text):
            ref = m.group(1).replace('\\', '/')
            # $PSScriptRoot is the folder of the script, $repo the root
            base = folder if '$PSScriptRoot' in m.group(0) or '${PSScriptRoot}' in m.group(0) else ''
            path = posixpath.normpath(posixpath.join(base, ref))
            if path.startswith('..'):
                continue
            if path not in have:
                missing.append((rel, path))
            elif path.endswith(('.ps1', '.py')) and os.path.isfile(os.path.join(root, path)):
                todo.append(path)
    return sorted(set(missing)), len(seen)


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    root = os.path.abspath(argv[1])
    have, mode = available(root)
    if not have:
        print('Test-BuildInputs: nothing to check against in %s' % root)
        return 2
    missing, scripts = scan(root, have, mode)
    for rel, path in missing:
        print('NOT EXPORTED: %s reads %s, which is not in the %s' % (rel, path, mode))
    if missing:
        print('Test-BuildInputs: %d file(s) a build needs are missing; export them in product.json.' % len(missing))
        return 1
    print('Test-BuildInputs: ok (%d scripts scanned, all files they read are present)' % scripts)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
