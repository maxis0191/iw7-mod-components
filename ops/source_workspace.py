"""Compose declared source inputs from exact Git revisions. No build or game data.

The result is a disposable build/test input package, never an editing checkout.
Canonical implementations remain in the repositories named by product.json.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys

MAX_TOTAL = 32 * 1024 * 1024
MAX_FILE = 1024 * 1024
FORBIDDEN = {'.exe', '.dll', '.pdb', '.obj', '.lib', '.ff', '.pak', '.xpak', '.sabs', '.sabl', '.dmp', '.cgsc', '.gscbin'}

def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], encoding='utf-8').strip()

def safe_relative(value):
    if not isinstance(value, str) or not value or '\\' in value or ':' in value:
        raise ValueError('Literal portable relative source path required')
    path = PurePosixPath(value)
    if path.is_absolute() or str(path) != value or any(p in ('', '.', '..') or p.endswith((' ', '.')) for p in path.parts):
        raise ValueError('Source path escapes its declared repository')
    if any(ord(c) < 32 for c in value) or path.suffix.lower() in FORBIDDEN or path.parts[0] in ('runtime', 'tools', 'backups', '.git'):
        raise ValueError('Runtime, binary or commercial payload refused')
    return path

def ordinary(path, *, missing=False):
    path = Path(os.path.abspath(path))
    for part in (path, *path.parents):
        try:
            meta = part.lstat()
        except FileNotFoundError:
            if missing:
                continue
            raise
        if stat.S_ISLNK(meta.st_mode) or getattr(meta, 'st_file_attributes', 0) & 0x400:
            raise ValueError('Redirected source or output ancestry refused: ' + str(part))
    return path

def prepare(project, revision, bindings, output):
    project = ordinary(project)
    output = ordinary(output, missing=True)
    if output.exists():
        raise ValueError('Fresh output directory required; existing data is never replaced')
    if not re.fullmatch('[0-9a-f]{40}', revision):
        raise ValueError('Exact project revision required')
    product = json.loads(git(project, 'show', revision + ':product.json'))
    if product.get('schema') != 'iw7.product/1':
        raise ValueError('Unknown product contract')
    requests = [{'id': product['id'], 'revision': revision, 'files': product['exports'], 'root': project}]
    for dependency in product['dependencies']:
        if dependency['id'] not in bindings:
            raise ValueError('Missing dependency binding: ' + dependency['id'])
        requests.append(dict(dependency, root=ordinary(bindings[dependency['id']])))
    entries, seen, total, revisions = [], set(), 0, {}
    for source in requests:
        root, commit = source['root'], source['revision']
        if not re.fullmatch('[0-9a-f]{40}', commit) or git(root, 'rev-parse', 'HEAD') != commit:
            raise ValueError('Dependency revision differs: ' + source['id'])
        if subprocess.run(['git', '-C', str(root), 'diff', '--quiet', 'HEAD']).returncode:
            raise ValueError('Dirty source checkout refused: ' + source['id'])
        tree = {}
        for row in git(root, 'ls-tree', '-r', commit).splitlines():
            info, name = row.split('\t', 1)
            mode, kind, blob = info.split()
            if kind == 'blob' and mode in ('100644', '100755'):
                tree[name] = blob
        revisions[source['id']] = commit
        for relative in source['files']:
            safe_relative(relative)
            if relative not in tree:
                raise ValueError('Untracked or absent declared source: ' + relative)
            if relative.casefold() in seen:
                raise ValueError('Multiple canonical owners for source path: ' + relative)
            seen.add(relative.casefold())
            file = ordinary(root / relative)
            size = file.stat().st_size
            if size > MAX_FILE or total + size > MAX_TOTAL:
                raise ValueError('Source composition byte budget exceeded')
            raw = file.read_bytes()
            raw.decode('utf-8-sig')
            if b'\x00' in raw or len(raw) != size:
                raise ValueError('Non-text or changing source input refused')
            total += size
            entries.append((relative, raw, dict(path=relative, owner=source['id'], commit=commit,
                            blob=tree[relative], bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())))
        # Batch Git's own attribute/filter-aware hash calculation: preserve CRLF
        # source contracts without pretending a Git blob is a checkout-byte hash.
        names = source['files']
        if names:
            hashes = subprocess.check_output(['git', '-C', str(root), 'hash-object', '--stdin-paths'],
                input='\n'.join(names) + '\n', encoding='utf-8').splitlines()
            if hashes != [tree[name] for name in names]:
                raise ValueError('Source input changed or differs from its Git revision')
    manifest = dict(schema='iw7.source-workspace/1', product=product['id'], revisions=revisions,
                    files=[entry[2] for entry in entries], bytes=total,
                    runtime_qualified=False, instruction='Edit canonical repositories, never this generated source package.')
    output.mkdir(parents=True, exist_ok=False)
    for relative, raw, _ in entries:
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open('xb') as stream:
            stream.write(raw)
    (output / 'source-workspace.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    verify(output)
    return manifest

def verify(output):
    output = ordinary(output)
    data = json.loads((output / 'source-workspace.json').read_text(encoding='utf-8'))
    if data.get('schema') != 'iw7.source-workspace/1':
        raise ValueError('Unknown source workspace')
    for entry in data['files']:
        safe_relative(entry['path'])
        raw = ordinary(output / entry['path']).read_bytes()
        if len(raw) != entry['bytes'] or hashlib.sha256(raw).hexdigest() != entry['sha256']:
            raise ValueError('Generated source changed: ' + entry['path'])
    return data

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path)
    parser.add_argument('--revision')
    parser.add_argument('--source', action='append', default=[], metavar='PRODUCT=CHECKOUT')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    try:
        if args.verify:
            result = verify(args.output)
        else:
            if not args.project or not args.revision:
                parser.error('--project and --revision are required')
            bindings = {}
            for item in args.source:
                name, separator, value = item.partition('=')
                if not separator or name in bindings:
                    raise ValueError('Unique PRODUCT=CHECKOUT bindings required')
                bindings[name] = value
            result = prepare(args.project, args.revision, bindings, args.output)
        print(json.dumps(dict(ok=True, product=result['product'], files=len(result['files']), bytes=result['bytes'], output=str(args.output))))
    except (ValueError, OSError, subprocess.SubprocessError, KeyError) as error:
        print(json.dumps(dict(ok=False, error=str(error))), file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
