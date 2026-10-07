"""Fixed eight-page, read-only acquisition; never attach/suspend/write a target."""
import argparse
import ctypes as c
from ctypes import wintypes as w
import hashlib
import json
from pathlib import Path
import sys
from datetime import datetime, timezone

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from iw7_capture import Observer, function

# Entry and demonstrated branch destinations only; no automatic graph expansion.
OWNERS = {
    '140488520': (0x140488520, 0x14BF22C47, 0x14BCE8A4C, 0x14B3785FF),
    '140B20760': (0x140B20760, 0x14BA00414, 0x14B7E7350, 0x14BA8E3FF),
}
PAGE = 4096


def plan():
    rows = []
    for owner, addresses in OWNERS.items():
        pages = sorted({address & ~(PAGE - 1) for address in addresses})
        if len(pages) > 4:
            raise ValueError('Owner page bound')
        rows.extend({'owner': owner, 'address': page, 'bytes': PAGE} for page in pages)
    if len(rows) != 8 or sum(x['bytes'] for x in rows) != 32768:
        raise ValueError('Fixed acquisition bound changed')
    return rows


def validate_region(region, address):
    # PAGE_EXECUTE alone is not admitted as readable; guard/noaccess forbidden.
    if region['state'] != 0x1000 or region['protect'] & 0x100 or region['protect'] & 0xff not in (0x20, 0x40, 0x80):
        raise ValueError('Page is not committed readable executable memory')
    if region['type'] not in (0x1000000, 0x20000, 0x40000):
        raise ValueError('Unclassified executable region')
    if region['base'] > address or region['base'] + region['bytes'] < address + PAGE:
        raise ValueError('Requested page crosses queried region')


def capture(reader, output):
    rows = plan()
    output = Path(output)
    if output.exists() or output.parent.is_symlink():
        raise ValueError('Fresh owned output required')
    output.mkdir()
    record = {'schema': 'iw7.capacity-code-pages/1', 'identity': reader.identity,
              'started_utc': datetime.now(timezone.utc).isoformat(), 'pages': [],
              'target_suspended': False, 'target_written': False, 'symbols_verified': False,
              'pristine': False, 'patch_ready': False, 'global_snapshot_coherent': False,
              'read_calls': 0, 'read_bytes': 0}
    try:
        for item in rows:
            reader.assert_alive()
            address = item['address']
            region = reader.region(address)
            validate_region(region, address)
            first = reader.read(address, PAGE)
            record['read_calls'] += 1
            record['read_bytes'] += len(first)
            second = reader.read(address, PAGE)
            record['read_calls'] += 1
            record['read_bytes'] += len(second)
            if len(first) != PAGE or len(second) != PAGE:
                raise ValueError('Partial memory read')
            name = f"{item['owner']}-{address:016X}.bin"
            with (output / name).open('xb') as stream:
                stream.write(first)
            entry = {**item, 'address': hex(address), 'path': name,
                     'sha256': hashlib.sha256(first).hexdigest(), 'region': region,
                     'stable_double_read': first == second}
            record['pages'].append(entry)
            if first != second or reader.region(address) != region:
                raise ValueError('Live page/protection changed during read; preserve partial capture')
        reader.assert_alive()
        record['completed_utc'] = datetime.now(timezone.utc).isoformat()
        record['complete'] = True
    except BaseException as error:
        record['complete'] = False
        record['failure'] = str(error)
        raise
    finally:
        with (output / 'manifest.local.json').open('x', encoding='utf-8') as stream:
            json.dump(record, stream, indent=2)
            stream.write('\n')
    return record


class Region(c.Structure):
    _fields_ = [('base', c.c_void_p), ('allocation', c.c_void_p), ('allocation_protect', w.DWORD),
                ('partition', w.WORD), ('size', c.c_size_t), ('state', w.DWORD),
                ('protect', w.DWORD), ('kind', w.DWORD)]


class WindowsReader:
    def __init__(self, observer):
        self.observer = observer
        self.identity = dict(observer.identity)
        self.query = function(observer.kernel, 'VirtualQueryEx',
                              [w.HANDLE, c.c_void_p, c.POINTER(Region), c.c_size_t], c.c_size_t)
        self.rpm = function(observer.kernel, 'ReadProcessMemory',
                            [w.HANDLE, c.c_void_p, c.c_void_p, c.c_size_t, c.POINTER(c.c_size_t)], w.BOOL)
        self.mapped = function(observer.psapi, 'GetMappedFileNameW',
                               [w.HANDLE, c.c_void_p, w.LPWSTR, w.DWORD], w.DWORD)
        if c.sizeof(Region) != 48:
            raise ValueError('Win64 MEMORY_BASIC_INFORMATION layout required')

    def assert_alive(self):
        if self.observer.wait(self.observer.handle, 0) != 258:
            raise ValueError('Original retained process handle no longer live')

    def region(self, address):
        info = Region()
        if self.query(self.observer.handle, c.c_void_p(address), c.byref(info), c.sizeof(info)) != c.sizeof(info):
            raise c.WinError(c.get_last_error())
        name = c.create_unicode_buffer(32768)
        n = self.mapped(self.observer.handle, c.c_void_p(address), name, len(name))
        return {'base': info.base, 'allocation_base': info.allocation, 'bytes': info.size,
                'state': info.state, 'protect': info.protect, 'allocation_protect': info.allocation_protect,
                'type': info.kind, 'mapped_device_path': name.value if n else None,
                'mapping_status': 'mapped-path-observed' if n else 'no-mapped-file-name',
                'code_origin': 'unclassified; mapped name/permissions do not establish retail or Arxan origin'}

    def read(self, address, size):
        buf = c.create_string_buffer(size)
        got = c.c_size_t()
        if not self.rpm(self.observer.handle, c.c_void_p(address), buf, size, c.byref(got)) or got.value != size:
            raise c.WinError(c.get_last_error())
        return buf.raw


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--image', required=True)
    parser.add_argument('--created', required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    runtime = Path(__file__).resolve().parents[2] / 'runtime' / 'agent-lab'
    destination = args.output.resolve()
    if not destination.is_relative_to(runtime.resolve()):
        parser.error('Owned Agent-Lab runtime output required')
    for parent in (args.output, *args.output.parents):
        if parent.exists() and (parent.is_symlink() or parent.is_junction()):
            parser.error('Redirected output refused')
    observer = Observer(args.pid, args.image, args.created, args.sha256)
    try:
        reader = WindowsReader(observer)
        reader.identity['image_path'] = str(Path(args.image).resolve())
        result = capture(reader, destination)
        print(json.dumps({'complete': result['complete'], 'pages': len(result['pages']), 'bytes': 32768,
                          'pristine': False, 'patch_ready': False, 'global_snapshot_coherent': False,
              'read_calls': 0, 'read_bytes': 0}))
    finally:
        observer.close()


if __name__ == '__main__':
    main()
