"""Small tracked-tree ownership and payload gate; no runtime directories scanned."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
from source_workspace import check_source_bytes, check_source_metadata, expand_exports, safe_relative

META = {'README.md', 'AGENTS.md', 'CONTRIBUTING.md', '.gitignore', '.gitattributes',
        'product.json', 'checks.json', 'dependency-package.json', 'bootstrap.ps1', 'checks.ps1', 'LICENSE.upstream'}

def check(root):
    product = json.loads((root / 'product.json').read_text(encoding='utf-8-sig'))
    exports = product['exports']
    if len(exports) != len(set(p.casefold() for p in exports)):
        raise ValueError('Duplicate product export')
    tracked = subprocess.check_output(['git','-C',str(root),'ls-files','--stage'], text=True).splitlines()
    # "<folder>/*.<ext>" exports own the files of that folder (one file per entry); the rest stay listed by name.
    declared = set(expand_exports(exports, [row.split('\t', 1)[1] for row in tracked]))
    foreign_file = root / 'migration/foreign-paths.json'
    foreign = set(json.loads(foreign_file.read_text(encoding='utf-8-sig'))) if foreign_file.exists() else set()
    if foreign & declared:
        raise ValueError('Another product owns declared paths: ' + ', '.join(sorted(foreign & declared)))
    contributions = set(declared)
    for dep in product['dependencies']:
        if len(dep['revision']) != 40 or dep['repository'] != 'https://github.com/maxis0191/' + dep['id'] + '.git':
            raise ValueError('Explicit owner repository and exact dependency commit required')
        for path in dep['files']:
            safe_relative(path)
            if path in contributions:
                raise ValueError('Duplicate canonical implementation: ' + path)
            contributions.add(path)
    names = set()
    for row in tracked:
        info, path = row.split('\t',1)
        mode, blob, _ = info.split()
        if mode not in ('100644','100755'):
            raise ValueError('Vendored submodule or redirected source refused: ' + path)
        names.add(path)
        safe_relative(path)
        if path in foreign:
            raise ValueError('Foreign product source copied into repository: ' + path)
        if path not in declared and path not in META and not path.startswith(('.github/', '.codex/', 'migration/', 'licenses/')):
            raise ValueError('Unclassified tracked component: ' + path)
        size = (root/path).stat().st_size
        check_source_metadata(product['id'], path, blob, size)
        raw = (root/path).read_bytes()
        check_source_bytes(product['id'], path, blob, raw)
    if declared - names:
        raise ValueError('Export missing from tracked tree: ' + ', '.join(sorted(declared-names)))
    for prefix in ('src/client/', 'src/zonetool/', 'deps/', 'vendor/', 'game/', 'zone/'):
        if any(p.startswith(prefix) for p in names):
            raise ValueError('Unreviewed complete engine/tool/game tree: ' + prefix)
    return dict(product=product['id'], tracked=len(names), exports=len(declared), dependencies=len(product['dependencies']))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    try:
        print(json.dumps(dict(ok=True, **check(parser.parse_args().root))))
    except (ValueError, OSError, KeyError) as error:
        print(json.dumps(dict(ok=False,error=str(error))),file=sys.stderr)
        raise SystemExit(1)
