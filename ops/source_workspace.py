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
import zipfile

MAX_TOTAL = 32 * 1024 * 1024
MAX_FILE = 1024 * 1024
FORBIDDEN = {'.exe', '.dll', '.pdb', '.obj', '.lib', '.ff', '.pak', '.xpak', '.sabs', '.sabl', '.dmp', '.cgsc', '.gscbin'}
# One reviewed finite constexpr table, not a configurable large-file allowance.
# Git blob and exported LF-byte identity are distinct and both are required.
_FINITE_SCHEMA_SOURCE = (
    'x64-zt-extensions',
    'tools-source/asset-bridge/weapon-export/native_pair_body_schema.hpp',
    '8eac8f40be1a306f48d30c0bdfdcbfdc45e0f666',
    1073140,
    'dbedd4632d8bb20686c8c1355d4b0200fc2c6149ba141897007f41252f555b75',
)
_UNRECORDED_DIGEST = object()


def check_source_metadata(owner, relative, blob, size, *, sha256=_UNRECORDED_DIGEST):
    expected_owner, expected_path, expected_blob, expected_size, expected_sha = _FINITE_SCHEMA_SOURCE
    # Reserve case variants before the generic cap, including smaller mutants.
    reserved = isinstance(relative, str) and relative.casefold() == expected_path.casefold()
    if reserved:
        if (type(owner) is not str or owner != expected_owner or
                type(relative) is not str or relative != expected_path or
                type(blob) is not str or blob != expected_blob or
                type(size) is not int or size != expected_size or
                (sha256 is not _UNRECORDED_DIGEST and
                 (type(sha256) is not str or sha256 != expected_sha))):
            raise ValueError('Finite schema Source identity differs')
    elif type(size) is not int or size < 0 or size > MAX_FILE:
        raise ValueError('Oversized or invalid source length: ' + str(relative))
    return reserved


def check_source_bytes(owner, relative, blob, raw):
    reserved = check_source_metadata(owner, relative, blob, len(raw))
    digest = hashlib.sha256(raw).hexdigest()
    if reserved and digest != _FINITE_SCHEMA_SOURCE[4]:
        raise ValueError('Finite schema Source bytes differ')
    # Check the reserved raw identity before decoding; BOM/CRLF are not aliases.
    raw.decode('utf-8-sig')
    if b'\x00' in raw:
        raise ValueError('Binary source payload refused: ' + relative)
    return digest


def read_source_entry(root, entry):
    """Recheck recorded identity and physical metadata before each source read."""
    relative = entry['path']
    safe_relative(relative)
    check_source_metadata(entry['owner'], relative, entry['blob'], entry['bytes'], sha256=entry['sha256'])
    file = ordinary(Path(root) / relative)
    size = file.stat().st_size
    check_source_metadata(entry['owner'], relative, entry['blob'], size, sha256=entry['sha256'])
    if type(entry['bytes']) is not int or size != entry['bytes']:
        raise ValueError('Generated source changed: ' + relative)
    raw = file.read_bytes()
    digest = check_source_bytes(entry['owner'], relative, entry['blob'], raw)
    if len(raw) != entry['bytes'] or digest != entry['sha256']:
        raise ValueError('Generated source changed: ' + relative)
    return raw

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

def export_pattern(value):
    """An export "<folder>/*<suffix>" owns every tracked file directly in that folder whose name ends with suffix (one file
    per entry folders: parallel branches add files there without editing product.json). -> (folder, suffix) or None."""
    if not isinstance(value, str) or '*' not in value:
        return None
    folder, _, leaf = value.rpartition('/')
    suffix = leaf[1:]
    if not folder or not leaf.startswith('*') or any(c in folder + suffix for c in '*?[]') or not suffix.startswith('.'):
        raise ValueError('Export pattern must be <folder>/*.<extension>: ' + value)
    safe_relative(folder + '/x' + suffix)
    return folder, suffix


def expand_exports(exports, names):
    """Literal exports plus the tracked names each pattern owns, in the order given; a path named twice is refused."""
    patterns = [(e, export_pattern(e)) for e in exports]
    owned = [p for _, p in patterns if p]
    if not owned:
        return list(exports)                         # no pattern: the list exactly as before
    out, seen = [], set()
    for entry, pattern in patterns:
        if pattern is None:
            if any(entry.rpartition('/')[0] == f and entry.endswith(s) for f, s in owned):
                raise ValueError('Export listed by name and by pattern: ' + entry)
            matched = [entry]
        else:
            folder, suffix = pattern
            matched = sorted(n for n in names if n.rpartition('/')[0] == folder and n.endswith(suffix) and len(n) > len(folder) + 1 + len(suffix))
        for name in matched:
            if name.casefold() in seen:
                raise ValueError('Duplicate product export: ' + name)
            seen.add(name.casefold())
            out.append(name)
    return out


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

def cached_source(dependency, cache):
    """Fetch one immutable source revision into a new cache entry, never reset."""
    ident, revision, url = dependency['id'], dependency['revision'], dependency['repository']
    if not re.fullmatch('[a-z0-9-]+', ident) or not re.fullmatch('[0-9a-f]{40}', revision):
        raise ValueError('Invalid source cache identity')
    if url != 'https://github.com/maxis0191/' + ident + '.git':
        raise ValueError('Only the explicitly owned private product source is supported')
    root = ordinary(Path(cache) / ident / revision, missing=True)
    if root.exists():
        if git(root, 'remote', 'get-url', 'origin') != url or git(root, 'rev-parse', 'HEAD') != revision:
            raise ValueError('Existing dependency cache identity differs; preserve it and use a fresh cache')
        return root
    root.mkdir(parents=True)
    for command in (
        ['init', '-q'], ['remote', 'add', 'origin', url],
        ['fetch', '--depth=1', '--no-tags', 'origin', revision], ['checkout', '--detach', 'FETCH_HEAD'],
    ):
        subprocess.run(['git', '-C', str(root), *command], check=True)
    if git(root, 'rev-parse', 'HEAD') != revision:
        raise ValueError('Fetched source revision differs')
    return root

def read_dependencies(project, revision, product, archive):
    lock = json.loads(git(project, 'show', revision + ':dependency-package.json'))
    archive = ordinary(archive)
    if archive.stat().st_size != lock['bytes'] or lock['bytes'] > MAX_TOTAL:
        raise ValueError('Dependency source archive length differs')
    if hashlib.sha256(archive.read_bytes()).hexdigest() != lock['sha256']:
        raise ValueError('Dependency source archive digest differs')
    expected = {(d['id'], d['revision'], p) for d in product['dependencies'] for p in d['files']}
    entries, seen, total = [], set(), 0
    with zipfile.ZipFile(archive) as package:
        infos = package.infolist()
        if len(infos) != len(expected) + 1 or len({i.filename.casefold() for i in infos}) != len(infos):
            raise ValueError('Incomplete or duplicate dependency archive')
        manifest_info = package.getinfo('dependencies.json')
        if manifest_info.file_size > MAX_FILE:
            raise ValueError('Dependency manifest too large')
        manifest = json.loads(package.read(manifest_info))
        if manifest.get('schema') != 'iw7.source-dependencies/1':
            raise ValueError('Unknown dependency source archive')
        for entry in manifest['files']:
            relative = entry['path']
            safe_relative(relative)
            identity = (entry['owner'], entry['commit'], relative)
            if identity not in expected or relative.casefold() in seen:
                raise ValueError('Unexpected dependency owner, revision or path')
            seen.add(relative.casefold())
            check_source_metadata(entry['owner'], relative, entry['blob'], entry['bytes'], sha256=entry['sha256'])
            info = package.getinfo(relative)
            check_source_metadata(entry['owner'], relative, entry['blob'], info.file_size, sha256=entry['sha256'])
            if info.file_size != entry['bytes'] or stat.S_ISLNK(info.external_attr >> 16):
                raise ValueError('Invalid dependency source member')
            total += info.file_size
            if total > MAX_TOTAL:
                raise ValueError('Dependency source budget exceeded')
            raw = package.read(info)
            digest = check_source_bytes(entry['owner'], relative, entry['blob'], raw)
            if len(raw) != entry['bytes'] or digest != entry['sha256']:
                raise ValueError('Dependency source member digest differs')
            entries.append((relative, raw, entry))
        if len(entries) != len(expected):
            raise ValueError('Missing dependency source member')
    return entries

def pack_dependencies(workspace, output):
    data = verify(workspace)
    output = ordinary(output, missing=True)
    entries = [e for e in data['files'] if e['owner'] != data['product']]
    metadata = dict(schema='iw7.source-dependencies/1', files=entries, runtime_qualified=False)
    manifest_raw = (json.dumps(metadata, sort_keys=True, indent=2)+'\n').encode()
    if len(manifest_raw) > MAX_FILE:
        raise ValueError('Dependency manifest too large')
    with output.open('xb') as destination, zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        members = []
        for entry in entries:
            raw = read_source_entry(workspace, entry)
            members.append((entry['path'], raw))
        members.append(('dependencies.json', manifest_raw))
        for name, raw in sorted(members):
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 13, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, raw)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    return dict(schema='iw7.source-dependency-package/1', name='dependencies.zip',
                tag='source-deps-' + digest[:16], sha256=digest, bytes=output.stat().st_size, files=len(entries),
                description='Exact source-only dependency exports; private build input, not a gameplay release.')

def prepare(project, revision, bindings, output, cache=None, package=None):
    project = ordinary(project)
    output = ordinary(output, missing=True)
    if output.exists():
        raise ValueError('Fresh output directory required; existing data is never replaced')
    if not re.fullmatch('[0-9a-f]{40}', revision):
        raise ValueError('Exact project revision required')
    product = json.loads(git(project, 'show', revision + ':product.json'))
    if product.get('schema') != 'iw7.product/1':
        raise ValueError('Unknown product contract')
    requests = [{'id': product['id'], 'revision': revision, 'files': product['exports'], 'root': project, 'patterns': True}]
    for dependency in ([] if package else product['dependencies']):
        if dependency['id'] not in bindings:
            if cache is None:
                raise ValueError('Missing dependency binding: ' + dependency['id'])
            bindings[dependency['id']] = cached_source(dependency, cache)
        requests.append(dict(dependency, root=ordinary(bindings[dependency['id']])))
    entries = read_dependencies(project, revision, product, package) if package else []
    seen = {e[0].casefold() for e in entries}
    total = sum(len(e[1]) for e in entries)
    revisions = {e[2]['owner']: e[2]['commit'] for e in entries}
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
        names = expand_exports(source['files'], tree) if source.get('patterns') else source['files']
        for relative in names:
            safe_relative(relative)
            if relative not in tree:
                raise ValueError('Untracked or absent declared source: ' + relative)
            if relative.casefold() in seen:
                raise ValueError('Multiple canonical owners for source path: ' + relative)
            seen.add(relative.casefold())
            file = ordinary(root / relative)
            size = file.stat().st_size
            check_source_metadata(source['id'], relative, tree[relative], size)
            if total + size > MAX_TOTAL:
                raise ValueError('Source composition byte budget exceeded')
            # Export committed content with Git's checkout filters. Reading the
            # object instead of mutable worktree bytes prevents a change/read/
            # restore race from forging the recorded revision. The physical
            # checkout is still required clean and checked again below. Resolve
            # versioned attributes from that same commit, including when sparse
            # checkout omits .gitattributes and local autocrlf differs.
            raw = subprocess.check_output(['git', '-C', str(root), '--attr-source=' + commit,
                                           'cat-file', '--filters', commit + ':' + relative])
            digest = check_source_bytes(source['id'], relative, tree[relative], raw)
            if total + len(raw) > MAX_TOTAL:
                raise ValueError('Non-text or oversized filtered source input refused')
            total += len(raw)
            entries.append((relative, raw, dict(path=relative, owner=source['id'], commit=commit,
                            blob=tree[relative], bytes=len(raw), sha256=digest)))
        # Batch Git's own attribute/filter-aware hash calculation: preserve CRLF
        # source contracts without pretending a Git blob is a checkout-byte hash.
        if names:
            hashes = subprocess.check_output(['git', '-C', str(root), '--attr-source=' + commit,
                                              'hash-object', '--stdin-paths'],
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
    seen, total = set(), 0
    for entry in data['files']:
        safe_relative(entry['path'])
        if entry['path'].casefold() in seen or entry['commit'] != data['revisions'].get(entry['owner']):
            raise ValueError('Duplicate or inconsistent source identity')
        seen.add(entry['path'].casefold())
        raw = read_source_entry(output, entry)
        total += len(raw)
    if total != data['bytes'] or total > MAX_TOTAL:
        raise ValueError('Generated source total differs')
    return data

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path)
    parser.add_argument('--revision')
    parser.add_argument('--source', action='append', default=[], metavar='PRODUCT=CHECKOUT')
    parser.add_argument('--cache', type=Path, help='Explicit source-only cache; missing bindings are fetched at exact revisions')
    parser.add_argument('--dependency-package', type=Path, help='Private source archive verified against the committed dependency lock')
    parser.add_argument('--pack-dependencies', type=Path, help='Write a deterministic source-only dependency archive from --output workspace')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    try:
        if args.pack_dependencies:
            print(json.dumps(pack_dependencies(args.output, args.pack_dependencies), indent=2))
            return 0
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
            result = prepare(args.project, args.revision, bindings, args.output, args.cache, args.dependency_package)
        print(json.dumps(dict(ok=True, product=result['product'], files=len(result['files']), bytes=result['bytes'], output=str(args.output))))
    except (ValueError, OSError, subprocess.SubprocessError, KeyError) as error:
        print(json.dumps(dict(ok=False, error=str(error))), file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
