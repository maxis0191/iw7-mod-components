#!/usr/bin/env python3
"""Export and build-list check for the fast compile check (ops/Compile-Check.ps1), in well under a second.

    python -B ops/compile_check_exports.py <repo root> src/native/agent_capacity.cpp [...]

For each given translation unit it follows the local #include "..." chain (files of src/native, .inc and .hpp too) and refuses, with the
file and the reason, when a file of that closure
  - is not named in product.json "exports" (a file the build copies but the product does not export is the fault a build only finds
    after minutes: the source workspace of a clean checkout lacks it), or
  - is not named in ops/Build-Voice.ps1 (the build copies only the files it lists into the native tree), or
  - does not exist.
It does not replace ops/check_boundaries.py (run by the caller first); it adds what that gate cannot see: a file that is still untracked.
Exit 0 ok, 1 a refusal (printed, one line each).
"""
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from source_workspace import expand_exports  # noqa: E402

INCLUDE = re.compile(r'^\s*#\s*include\s+"([^"]+)"', re.M)


def closure(native, first):
    """Files of src/native reached from `first` by local includes (path relative to the repo, forward slashes)."""
    seen, order, todo = set(), [], [first]
    missing = []
    while todo:
        path = todo.pop()
        if path in seen:
            continue
        seen.add(path)
        order.append(path)
        file = native / path
        if not file.is_file():
            missing.append(path)
            continue
        for name in INCLUDE.findall(file.read_text(encoding='utf-8', errors='replace')):
            target = (file.parent / name).resolve()
            try:
                rel = target.relative_to(native.resolve()).as_posix()
            except ValueError:
                continue                       # an engine / system header: not ours
            if (native / rel).is_file():
                todo.append(rel)
    return order, missing


def check(repo, sources):
    repo = Path(repo).resolve()
    native = repo / 'src' / 'native'
    try:
        names = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '--cached', '--others', '--exclude-standard'], text=True,
                                        stderr=subprocess.DEVNULL).splitlines()
    except (subprocess.CalledProcessError, OSError):      # a prepared source workspace (bootstrap.ps1 output) is not a git checkout
        names = [p.relative_to(repo).as_posix() for p in repo.rglob('*') if p.is_file() and '.git' not in p.parts]
    product = json.loads((repo / 'product.json').read_text(encoding='utf-8-sig'))
    exported = {n.casefold() for n in expand_exports(product['exports'], names)}
    build = (repo / 'ops' / 'Build-Voice.ps1').read_text(encoding='utf-8', errors='replace')
    errors, total = [], []
    for source in sources:
        rel = Path(source).as_posix()
        rel = rel[len('src/native/'):] if rel.startswith('src/native/') else rel
        order, missing = closure(native, rel)
        errors += ['%s: included by %s but the file does not exist in src/native' % (m, rel) for m in missing]
        for path in order:
            if path in missing:
                continue
            total.append(path)
            full = 'src/native/' + path
            if full.casefold() not in exported:
                errors.append('%s: not in product.json "exports" (needed by %s)' % (full, rel))
            if re.search(r"'%s'" % re.escape(Path(path).name), build) is None:
                errors.append('%s: not listed in ops/Build-Voice.ps1 (the build would not copy it into the native tree)' % full)
    return errors, sorted(set(total))


if __name__ == '__main__':
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    problems, files = check(sys.argv[1], sys.argv[2:])
    for line in problems:
        print('REFUSED ' + line)
    print('%d file(s) in the include closure; %s' % (len(files), 'ok' if not problems else '%d problem(s)' % len(problems)))
    sys.exit(1 if problems else 0)
