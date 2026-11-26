#!/usr/bin/env python3
"""Fast ownership gate (about 1 s, no bootstrap, no network): the product rules of the full local judge, before the commit.

The full judge (bootstrap.ps1 + checks.ps1) takes 5 to 6 minutes and used to fail at the very end for a tracked file
missing from product.json "exports", unsorted or CRLF exports, or a binary or forbidden-suffix source. This runs the same
rules over `git ls-files` and the working tree in about a second:

  1. product.json is LF and its "exports" list is one path a line, sorted, without duplicates or conflict markers.
  2. Every tracked file is classified (exported, a META file, or under .github/ .codex/ migration/ licenses/).
  3. Every export is tracked; no submodule or redirected source; no engine/game tree prefixes.
  4. Every source passes the source-composition payload rules: not over the size cap, no forbidden suffix, valid utf-8,
     no NUL byte (a PNG or any extracted payload is refused).
  5. Dependency entries and migration/foreign-paths.json as in check_boundaries.py.

The rules come from the repository's own ops/source_workspace.py when it has one, else from the pinned dependency archive
(machine cache C:\\IW7-Cache or $IW7_BUILD_CACHE, or an extracted runtime/bootstrap copy), else from a small copy below
that mirrors them. The first line printed says which.

  python -B ops/quality/fast_gate.py            check; exit 1 and the fix command on a problem
  python -B ops/quality/fast_gate.py --fix      add unclassified files to exports, sort them, LF, then check again
  python -B ops/quality/fast_gate.py --install-hook   opt-in: this clone's .git/hooks/pre-commit runs the check (no global hook)
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import types
import zipfile
from pathlib import Path, PurePosixPath

META = {'README.md', 'AGENTS.md', 'CONTRIBUTING.md', '.gitignore', '.gitattributes',
        'product.json', 'checks.json', 'dependency-package.json', 'bootstrap.ps1', 'checks.ps1', 'LICENSE.upstream'}
FREE_PREFIXES = ('.github/', '.codex/', 'migration/', 'licenses/')
BANNED_TREES = ('src/client/', 'src/zonetool/', 'deps/', 'vendor/', 'game/', 'zone/')
HOOK_MARK = '# iw7-fast-gate'
EXPORTS_RE = re.compile(r'("exports"\s*:\s*\[\n)(.*?)(\n[ \t]*\])', re.S)
MARKER_RE = re.compile(r'^(<{7}|\|{7}|={7}|>{7})')


# ---- the rules: the repository's own recipe when present, else this mirror -------------------------------------------

class Mirror:
    """Same rules as ops/source_workspace.py (read at the time of writing); used only when no recipe copy is found."""
    origin = 'built-in mirror of source_workspace.py (no recipe copy found)'
    MAX_FILE = 1024 * 1024
    FORBIDDEN = {'.exe', '.dll', '.pdb', '.obj', '.lib', '.ff', '.pak', '.xpak', '.sabs', '.sabl', '.dmp', '.cgsc', '.gscbin'}

    def safe_relative(self, value):
        if not isinstance(value, str) or not value or '\\' in value or ':' in value:
            raise ValueError('Literal portable relative source path required')
        path = PurePosixPath(value)
        if path.is_absolute() or str(path) != value or any(p in ('', '.', '..') or p.endswith((' ', '.')) for p in path.parts):
            raise ValueError('Source path escapes its declared repository')
        if any(ord(c) < 32 for c in value) or path.suffix.lower() in self.FORBIDDEN or path.parts[0] in ('runtime', 'tools', 'backups', '.git'):
            raise ValueError('Runtime, binary or commercial payload refused')

    def check_source_bytes(self, owner, relative, blob, raw):
        if len(raw) > self.MAX_FILE:
            raise ValueError('Oversized or invalid source length: ' + relative)
        raw.decode('utf-8-sig')
        if b'\x00' in raw:
            raise ValueError('Binary source payload refused: ' + relative)

    def expand_exports(self, exports, names):
        return list(exports)


class Recipe:
    def __init__(self, module, origin):
        self.m, self.origin = module, origin

    def safe_relative(self, value):
        self.m.safe_relative(value)

    def check_source_bytes(self, owner, relative, blob, raw):
        self.m.check_source_bytes(owner, relative, blob, raw)

    def expand_exports(self, exports, names):
        fn = getattr(self.m, 'expand_exports', None)
        return fn(exports, names) if fn else list(exports)


def _module_from(text, origin):
    mod = types.ModuleType('source_workspace')
    mod.__file__ = origin
    exec(compile(text, origin, 'exec'), mod.__dict__)
    return mod


def load_rules(root):
    own = root / 'ops' / 'source_workspace.py'
    try:
        if own.is_file():
            return Recipe(_module_from(own.read_text(encoding='utf-8'), str(own)), 'repository ops/source_workspace.py')
        lock = json.loads((root / 'dependency-package.json').read_text(encoding='utf-8-sig'))
        sha, name = lock['sha256'], lock['name']
        homes = [root]
        try:  # the main checkout next to a worktree keeps the extracted bootstrap
            common = subprocess.check_output(['git', '-C', str(root), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                                             text=True, stderr=subprocess.DEVNULL).strip()
            homes.append(Path(common).parent)
        except (subprocess.SubprocessError, OSError):
            pass
        for home in homes:
            cand = home / 'runtime' / 'bootstrap' / sha / 'source_workspace.py'
            if cand.is_file():
                return Recipe(_module_from(cand.read_text(encoding='utf-8'), str(cand)), 'extracted bootstrap ' + sha[:12])
        cache = Path(os.environ.get('IW7_BUILD_CACHE') or 'C:\\IW7-Cache')
        zips = [cache / 'source-dependencies' / sha / name] + [h / 'runtime' / 'source-dependencies' / sha / name for h in homes]
        for z in zips:
            if z.is_file():
                with zipfile.ZipFile(z) as zf:
                    return Recipe(_module_from(zf.read('ops/source_workspace.py').decode('utf-8'), str(z) + '!ops/source_workspace.py'),
                                  'cached dependency archive ' + sha[:12])
    except Exception as error:  # a damaged copy must not hide the check itself
        print('fast_gate: recipe copy unusable (%s); using the built-in mirror' % error, file=sys.stderr)
    return Mirror()


# ---- reading the repository --------------------------------------------------------------------------------------------

def git_toplevel():
    return Path(__file__).resolve().parents[2]


def tracked(root):
    out = subprocess.check_output(['git', '-C', str(root), 'ls-files', '--stage', '-z'])
    rows = []
    for rec in out.split(b'\0'):
        if rec:
            info, path = rec.decode('utf-8').split('\t', 1)
            mode, blob, _ = info.split()
            rows.append((mode, blob, path))
    return rows


def read_exports(root):
    """(raw bytes, normalized text, match, paths, marked, bad-lines); the same reader as checks.ps1 -SortExports."""
    raw = (root / 'product.json').read_bytes()
    text = raw.decode('utf-8-sig').replace('\r\n', '\n')
    m = EXPORTS_RE.search(text)
    if not m:
        return raw, text, None, [], False, []
    paths, marked, bad = [], False, []
    for line in m.group(2).split('\n'):
        s = line.strip()
        if MARKER_RE.match(s):
            marked = True
        elif (g := re.match(r'^"([^"\\]+)",?$', s)):
            paths.append(g.group(1))
        elif s:
            bad.append(s)
    return raw, text, m, paths, marked, bad


def write_exports(root, raw, text, m, paths):
    want = sorted(set(paths))
    body = m.group(2).split('\n')
    indent = re.match(r'^[ \t]*', next((l for l in body if l.strip().startswith('"')), '    ')).group(0)
    new = '\n'.join(indent + '"' + p + '"' + (',' if i < len(want) - 1 else '') for i, p in enumerate(want))
    text = text[:m.start(2)] + new + text[m.end(2):]
    (root / 'product.json').write_bytes((b'\xef\xbb\xbf' if raw.startswith(b'\xef\xbb\xbf') else b'') + text.encode('utf-8'))
    return len(want)


# ---- the checks ---------------------------------------------------------------------------------------------------------

def run_checks(root, rules):
    """Return (problems, unclassified-and-clean, stats); a problem is (kind, subject, message)."""
    problems, fixable = [], []
    raw, text, m, paths, marked, bad = read_exports(root)
    if b'\r\n' in raw:
        problems.append(('crlf', 'product.json', 'product.json has CRLF line ends (the sort checker of an SDK checkout reports "no exports list")'))
    if not m:
        problems.append(('exports', 'product.json', 'no "exports" list, one quoted path a line'))
        return problems, fixable, {}
    if marked or re.search(r'^(<{7}|={7}|>{7})', text[:m.start()] + text[m.end():], re.M):
        problems.append(('conflict', 'product.json', 'merge conflict markers in product.json: resolve by hand (or checks.ps1 -SortExports)'))
    for line in bad[:3]:
        problems.append(('exports', 'product.json', 'unexpected line in exports: ' + line))
    if paths != sorted(set(paths)):
        wrong = next((p for p, q in zip(paths, sorted(set(paths))) if p != q), 'a repeated path')
        problems.append(('sort', 'product.json', 'exports are not sorted or repeat a path (first out of place: %s)' % wrong))
    try:
        product = json.loads(text)
    except ValueError as error:
        problems.append(('exports', 'product.json', 'not valid JSON: %s' % error))
        return problems, fixable, {}
    exports = product.get('exports', [])
    rows = tracked(root)
    names = [p for _, _, p in rows]
    if len(exports) != len({p.casefold() for p in exports}):
        problems.append(('duplicate', 'product.json', 'Duplicate product export (case-insensitive)'))
    try:
        declared = set(rules.expand_exports(exports, names))
    except ValueError as error:
        problems.append(('exports', 'product.json', str(error)))
        declared = set(exports)
    foreign_file = root / 'migration' / 'foreign-paths.json'
    foreign = set(json.loads(foreign_file.read_text(encoding='utf-8-sig'))) if foreign_file.is_file() else set()
    if foreign & declared:
        problems.append(('foreign', 'product.json', 'Another product owns declared paths: ' + ', '.join(sorted(foreign & declared))))
    contributions = set(declared)
    for dep in product.get('dependencies', []):
        if len(dep['revision']) != 40 or dep['repository'] != 'https://github.com/maxis0191/' + dep['id'] + '.git':
            problems.append(('dependency', dep.get('id', '?'), 'Explicit owner repository and exact dependency commit required'))
        for path in dep['files']:
            try:
                rules.safe_relative(path)
            except ValueError as error:
                problems.append(('dependency', path, str(error)))
            if path in contributions:
                problems.append(('dependency', path, 'Duplicate canonical implementation'))
            contributions.add(path)
    owner = product.get('id', '')
    for mode, blob, path in rows:
        if mode not in ('100644', '100755'):
            problems.append(('mode', path, 'Vendored submodule or redirected source refused'))
            continue
        clean = True
        try:
            rules.safe_relative(path)
        except ValueError as error:
            problems.append(('payload', path, str(error)))
            continue
        if path in foreign:
            problems.append(('foreign', path, 'Foreign product source copied into repository'))
            continue
        full = root / path
        try:
            size = full.stat().st_size
            if size > 1024 * 1024 and not isinstance(rules, Recipe):
                raise ValueError('Oversized or invalid source length: ' + path)
            rules.check_source_bytes(owner, path, blob, full.read_bytes())
        except FileNotFoundError:
            problems.append(('missing', path, 'tracked but absent from the working tree (git rm or restore it)'))
            continue
        except (ValueError, OSError) as error:  # UnicodeDecodeError is a ValueError: a PNG lands here
            problems.append(('payload', path, '%s (%s)' % (error, 'binary or extracted payloads must stay out of the repository')))
            clean = False
        if path not in declared and path not in META and not path.startswith(FREE_PREFIXES):
            if clean:
                fixable.append(path)
            problems.append(('unclassified', path, 'Unclassified tracked component: not in product.json exports'))
    for path in sorted(declared - set(names)):
        problems.append(('stale', path, 'Export missing from tracked tree (git add the file or drop the export)'))
    for prefix in BANNED_TREES:
        if any(n.startswith(prefix) for n in names):
            problems.append(('tree', prefix, 'Unreviewed complete engine/tool/game tree'))
    return problems, fixable, dict(tracked=len(names), exports=len(declared))


def report(problems, limit=15):
    by_kind = {}
    for kind, subject, message in problems:
        by_kind.setdefault(kind, []).append((subject, message))
    for kind, items in by_kind.items():
        for subject, message in items[:limit]:
            print('  [%s] %s: %s' % (kind, subject, message))
        if len(items) > limit:
            print('  [%s] ... and %d more' % (kind, len(items) - limit))


def install_hook(root, force):
    hooks = Path(subprocess.check_output(['git', '-C', str(root), 'rev-parse', '--path-format=absolute', '--git-path', 'hooks'],
                                         text=True).strip())
    hooks.mkdir(parents=True, exist_ok=True)
    target = hooks / 'pre-commit'
    if target.exists() and HOOK_MARK not in target.read_text(encoding='utf-8', errors='replace') and not force:
        print('fast_gate: %s already holds another pre-commit hook; add the line below to it, or re-run with --force:' % target)
        print('  python -B "$(git rev-parse --show-toplevel)/ops/quality/fast_gate.py" --hook || exit 1')
        return 1
    target.write_bytes(('#!/bin/sh\n%s: installed by ops/quality/fast_gate.py --install-hook; remove this file to opt out\n'
                        'top=$(git rev-parse --show-toplevel)\n[ -f "$top/ops/quality/fast_gate.py" ] || exit 0\n'
                        'exec python -B "$top/ops/quality/fast_gate.py" --hook\n' % HOOK_MARK).encode('utf-8'))
    try:
        target.chmod(0o755)
    except OSError:
        pass
    print('fast_gate: pre-commit hook installed for this clone and its worktrees: ' + str(target))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--fix', action='store_true', help='add unclassified files to exports, sort, LF, then check again')
    ap.add_argument('--hook', action='store_true', help='pre-commit mode: quiet when clean')
    ap.add_argument('--install-hook', action='store_true', help='install the opt-in pre-commit hook in this clone')
    ap.add_argument('--force', action='store_true', help='with --install-hook: replace another pre-commit hook')
    ap.add_argument('--root', type=Path, help='check another checkout (default: the one this script is in)')
    args = ap.parse_args()
    root = (args.root or git_toplevel()).resolve()
    if args.install_hook:
        return install_hook(root, args.force)
    started = time.perf_counter()
    rules = load_rules(root)
    problems, fixable, stats = run_checks(root, rules)
    if args.fix and problems:
        raw, text, m, paths, marked, bad = read_exports(root)
        fixed = []
        if m and not marked and not bad:
            add = [p for p in fixable if p not in paths]
            if add or b'\r\n' in raw or paths != sorted(set(paths)):
                count = write_exports(root, raw, text, m, paths + add)
                print('fast_gate --fix: product.json written LF, %d exports sorted (%d added)' % (count, len(add)))
                fixed = add
                for p in add:
                    print('  + ' + p)
        if fixed or b'\r\n' in raw:
            problems, fixable, stats = run_checks(root, rules)
    elapsed = time.perf_counter() - started
    if problems:
        print('fast_gate FAILED (%.2f s, rules: %s): the full judge would fail on these.' % (elapsed, rules.origin))
        report(problems)
        if any(k in ('unclassified', 'sort', 'crlf') for k, _, _ in problems) and not args.fix:
            print('  fix the classification, order and line ends with: python -B ops/quality/fast_gate.py --fix')
        return 1
    if not args.hook:
        print('fast_gate ok (%.2f s, rules: %s): %d tracked, %d exports' % (elapsed, rules.origin, stats['tracked'], stats['exports']))
    return 0


if __name__ == '__main__':
    sys.exit(main())
