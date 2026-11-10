#!/usr/bin/env python3
"""Turn a crash dump of a game client into a readable stack with function names.

    report DUMP [--map MAP.sqlite] [--reference-root DIR] [--all-threads] [--json] [--max-frames N]

DUMP is a .dmp file or a .zip that holds one. The exception, the place it happened, the registers and a scanned list of
return addresses are named through the engine map (iw7_engine_map.py) and the module list of the dump.
This is not a full unwind: see docs/CRASH.md.
"""
import argparse
import bisect
import json
import mmap
import os
import sqlite3
import struct
import sys
import zipfile
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import iw7_engine_map  # noqa: E402

SCHEMA = 'iw7.crash-stack/1'
GAME_BASE = 0x140000000
GAME_TEXT = 0x140001000
STACK_LIMIT = 8 * 1024 * 1024          # most stack bytes scanned for one thread
OTHER_THREAD_FRAMES = 5
EXCEPTIONS = {0xC0000005: 'access violation', 0xC00000FD: 'stack overflow', 0x80000003: 'breakpoint',
              0xC0000409: 'fail-fast', 0xE06D7363: 'C++ exception'}
REGISTERS = (('rax', 120), ('rcx', 128), ('rdx', 136), ('rbx', 144), ('rsp', 152), ('rbp', 160), ('rsi', 168), ('rdi', 176),
             ('r8', 184), ('r9', 192), ('r10', 200), ('r11', 208), ('r12', 216), ('r13', 224), ('r14', 232), ('r15', 240), ('rip', 248))
CONTEXT_MIN = 256
NOTE = ('This list is scanned from the stack, not unwound. It can contain addresses left behind by earlier calls. '
        'The first verified entries after the crash point are the most reliable.')


class CrashError(Exception):
    """A problem with the input that the user can read: reported with exit code 2."""


def load_debugger():
    """The existing minidump reader of the project, imported by path."""
    path = os.path.join(os.path.dirname(HERE), 'iw7_debugger.py')
    if not os.path.isfile(path):
        raise CrashError('the minidump reader %s is missing' % path)
    spec = importlib.util.spec_from_file_location('iw7_debugger', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def hx(v):
    return '0x%X' % v


# ------------------------------------------------------------------------------------------------ the dump

class Dump:
    """What the existing reader does not give: threads with their stacks and contexts, memory ranges, regions, the context record."""

    def __init__(self, data, dbg):
        self.md = dbg.MiniDump(data)
        self.summary = self.md.summary()                      # modules, the exception record, the thread count
        self.modules = sorted((int(m['base'], 16), m['size'], m['name']) for m in self.summary['modules'])
        self.module_bases = [m[0] for m in self.modules]
        self.threads = self.read_threads()
        self.ranges = self.read_ranges()
        self.regions = self.read_regions()
        self.exception = self.read_exception()

    def read_threads(self):
        s = self.md.stream(3, 4)
        if not s:
            return []
        pos, size = s
        count, = self.md.unpack('<I', pos)
        if count > 100000 or 4 + count * 48 > size:
            raise ValueError('Invalid thread list')
        out = []
        for i in range(count):
            p = pos + 4 + i * 48
            tid, = self.md.unpack('<I', p)
            start, length, rva = self.md.unpack('<QII', p + 24)
            ctx_size, ctx_rva = self.md.unpack('<II', p + 40)
            out.append({'id': tid, 'stack': (start, length, rva), 'context': (ctx_size, ctx_rva)})
        return out

    def read_ranges(self):
        """Every captured piece of memory as (start, size, file offset), sorted by start."""
        ranges = [t['stack'] for t in self.threads if t['stack'][1]]
        s = self.md.stream(5, 4)
        if s:
            pos, size = s
            count, = self.md.unpack('<I', pos)
            if count > 10000000 or 4 + count * 16 > size:
                raise ValueError('Invalid memory list')
            for i in range(count):
                start, length, rva = self.md.unpack('<QII', pos + 4 + i * 16)
                ranges.append((start, length, rva))
        s = self.md.stream(9, 16)
        if s:
            pos, size = s
            count, rva = self.md.unpack('<QQ', pos)
            if count > 10000000 or 16 + count * 16 > size:
                raise ValueError('Invalid memory64 list')
            for i in range(count):
                start, length = self.md.unpack('<QQ', pos + 16 + i * 16)
                ranges.append((start, length, rva))
                rva += length
        return sorted(set(ranges))

    def read_regions(self):
        """Protection of the address space when the dump has the memory info list; None when it does not."""
        s = self.md.stream(16, 16)
        if not s:
            return None
        pos, size = s
        header, entry, count = self.md.unpack('<IIQ', pos)
        if entry < 32 or header < 16 or count > 10000000 or header + count * entry > size:
            raise ValueError('Invalid memory info list')
        out = []
        for i in range(count):
            p = pos + header + i * entry
            base, _alloc, _aprot, _pad, length, _state, protect = self.md.unpack('<QQIIQII', p)
            out.append((base, length, protect))
        return sorted(out)

    def read_exception(self):
        e = self.summary['exception']
        if not e:
            return None
        pos, _ = self.md.streams[6]
        ctx_size, ctx_rva = self.md.unpack('<II', pos + 160)
        out = {'thread_id': e['thread_id'], 'code': int(e['code'], 16), 'address': int(e['address'], 16),
               'parameters': [int(x, 16) for x in e['parameters']], 'context': (ctx_size, ctx_rva)}
        return out

    def registers(self, context):
        size, rva = context
        if size < CONTEXT_MIN:
            return None
        raw = self.md.slice(rva, CONTEXT_MIN)
        regs = {name: struct.unpack_from('<Q', raw, off)[0] for name, off in REGISTERS}
        regs['eflags'] = struct.unpack_from('<I', raw, 68)[0]
        return regs

    def read_from(self, va, limit):
        """Captured bytes from va to the end of the range that holds it, at most limit; None when va is not captured."""
        i = bisect.bisect_right(self.ranges, (va, 1 << 64, 0)) - 1
        for j in range(i, max(-1, i - 8), -1):
            start, length, rva = self.ranges[j]
            if start <= va < start + length:
                n = min(start + length - va, limit)
                return self.md.slice(rva + va - start, n)
        return None

    def module_at(self, va):
        i = bisect.bisect_right(self.module_bases, va) - 1
        if i >= 0:
            base, size, name = self.modules[i]
            if va < base + size:
                return base, size, name
        return None

    def executable(self, va):
        """True/False from the protection of the region; None when the dump has no region information."""
        if self.regions is None:
            return None
        i = bisect.bisect_right(self.regions, (va, 1 << 64, 0)) - 1
        if i >= 0:
            base, length, protect = self.regions[i]
            return va < base + length and bool(protect & 0xF0)
        return False


# ------------------------------------------------------------------------------------------------ naming and checking

class Analyzer:
    def __init__(self, dump, engine_map=None, reference=None):
        self.dump = dump
        self.map = engine_map
        self.ref = reference                                   # (bytes of unpacked-text.bin, its address)
        self.game = None                                       # (first, end) of the game code
        if engine_map is not None:
            first = int(engine_map.meta['text_va'])
            self.game = (first, first + int(engine_map.meta['text_bytes']))
            self.base = engine_map.base
        elif reference is not None:
            self.game = (reference[1], reference[1] + len(reference[0]))
            self.base = GAME_BASE
        self.game_module = dump.module_at(self.game[0]) if self.game else None
        if reference is not None:
            import capstone
            self.cs = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
        self.cache = {}
        self.mode = ('bytes before the return address decode as one call instruction' if reference is not None else
                     'a direct call in the engine map (indirect calls cannot be verified without --reference-root)' if engine_map is not None else
                     'none: the game image cannot be checked without --map or --reference-root')

    def in_game(self, va):
        return self.game is not None and self.game[0] <= va < self.game[1]

    def locate(self, va):
        """Where an address is: the game function, a module, or nowhere."""
        if self.in_game(va):
            if self.map is not None and self.map.func(va) is not None:
                f = self.map.func(va)
                return {'kind': 'game', 'label': self.map.label(va), 'function': hx(f), 'offset': va - f, 'module': None}
            return {'kind': 'game', 'label': 'game+0x%X' % (va - self.base), 'function': None, 'offset': va - self.base, 'module': None}
        m = self.dump.module_at(va)
        if m:
            return {'kind': 'module', 'label': '%s+0x%X' % (m[2], va - m[0]), 'function': None, 'offset': va - m[0], 'module': m[2]}
        return {'kind': 'none', 'label': 'not in any module', 'function': None, 'offset': None, 'module': None}

    def verify(self, va):
        """('direct' or 'indirect', call site) when a call instruction ends at va, else None."""
        if va in self.cache:
            return self.cache[va]
        got = None
        if self.ref is not None:
            text, first = self.ref
            for length in range(2, 8):
                lo = va - length
                if lo < first or va > first + len(text):
                    continue
                code = text[lo - first:va - first]
                ins = list(self.cs.disasm_lite(code, lo))
                if len(ins) == 1 and ins[0][1] == length and ins[0][2].split()[-1] == 'call':
                    got = ('direct' if code[0] == 0xE8 and length == 5 else 'indirect', lo)
                    break
        elif self.map is not None:
            row = self.map.db.execute("select 1 from calls where site = ? and kind = 'call'", (va - 5,)).fetchone()
            if row:
                got = ('direct', va - 5)
        self.cache[va] = got
        return got

    def candidate(self, va):
        """None to drop the value, else a stack entry."""
        if self.in_game(va):
            v = self.verify(va)
            if v is None:
                return None
            e = self.locate(va)
            e.update(status='verified call', call=v[0], call_site=hx(v[1]))
            return e
        m = self.dump.module_at(va)
        if m is None:
            return None
        if self.game_module is not None and m[0] == self.game_module[0]:
            return None                                        # the game image outside its code section is not code
        if self.dump.executable(va) is False:
            return None
        e = self.locate(va)
        e.update(status='unverified', call=None, call_site=None)
        return e

    def scan(self, rsp, limit):
        """Return-address entries from the stack at rsp, at most limit, or (None, why) when the stack is not in the dump."""
        data = self.dump.read_from(rsp, STACK_LIMIT)
        if data is None:
            return None, 'the stack at %s is not in the dump' % hx(rsp)
        n = len(data) // 8
        values = struct.unpack('<%dQ' % n, data[:n * 8])
        out, scanned = [], len(data)
        for i, v in enumerate(values):
            if v < 0x10000:
                continue
            e = self.candidate(v)
            if e is None:
                continue
            if e['status'] == 'unverified' and out and out[-1]['status'] == 'unverified' and out[-1]['module'] == e['module']:
                continue                                       # one unverified entry per module in a row
            e.update(offset_from_rsp=i * 8, address=hx(v))
            out.append(e)
            if len(out) >= limit:
                scanned = (i + 1) * 8
                break
        return out, '%d bytes of stack scanned' % scanned


# ------------------------------------------------------------------------------------------------ the report

def describe_exception(x):
    code = x['code']
    out = {'code': '0x%08X' % code, 'name': EXCEPTIONS.get(code), 'thread_id': x['thread_id'], 'address': hx(x['address']),
           'parameters': [hx(p) for p in x['parameters']]}
    p = x['parameters']
    if code == 0xC0000005 and len(p) >= 2:
        out['access'] = {0: 'read', 1: 'write', 8: 'execute'}.get(p[0], 'unknown')
        out['target'] = hx(p[1])
    if code == 0xC0000409 and p:
        out['fast_fail_code'] = p[0]
    return out


def thread_report(an, thread, regs, frames):
    out = {'thread_id': thread['id'], 'rip': None, 'location': None, 'stack': None}
    if regs is None:
        out['note'] = 'the context of this thread is not in the dump'
        return out
    out['rip'] = hx(regs['rip'])
    out['location'] = an.locate(regs['rip'])
    entries, note = an.scan(regs['rsp'], frames)
    out['stack'] = entries
    out['stack_note'] = note
    return out


def build_report(args, path, dump, an):
    rep = {'schema': SCHEMA, 'dump': os.path.basename(path), 'modules': len(dump.modules), 'threads': len(dump.threads),
           'map': os.path.basename(args.map) if args.map else None, 'verification': an.mode, 'exception': None}
    x = dump.exception
    crash_thread = None
    if x:
        rep['exception'] = describe_exception(x)
        crash_thread = x['thread_id']
        regs = dump.registers(x['context'])
        rep['crash_address_location'] = an.locate(x['address'])
        rep['registers'] = {k: hx(v) for k, v in regs.items()} if regs else None
        if regs is None:
            rep['stack'] = {'tier': 'return addresses', 'entries': [], 'note': 'the context record of the exception is not in the dump'}
        else:
            entries, note = an.scan(regs['rsp'], args.max_frames)
            rep['stack'] = {'tier': 'return addresses', 'entries': entries or [], 'note': note, 'rsp': hx(regs['rsp'])}
    others = []
    if args.all_threads or not x:
        for t in dump.threads:
            if t['id'] == crash_thread:
                continue
            others.append(thread_report(an, t, dump.registers(t['context']), OTHER_THREAD_FRAMES))
        rep['other_threads'] = others
    rep['summary'] = summary_line(rep)
    return rep


def summary_line(rep):
    x = rep['exception']
    if not x:
        return 'dump without an exception record, %d threads' % rep['threads']
    name = x['name'] or x['code']
    if 'access' in x:
        name += ' (%s)' % x['access']
    line = 'crash %s at %s' % (name, rep['crash_address_location']['label'])
    verified = [e['label'] for e in rep['stack']['entries'] if e['status'] == 'verified call'][:2]
    if verified:
        return line + ', called from ' + ', '.join(verified)
    return line + ', no verified return address found'


def render(rep):
    L = []
    x = rep['exception']
    L.append('dump %s: %d threads, %d modules' % (rep['dump'], rep['threads'], rep['modules']))
    L.append('engine map: %s; return addresses checked by: %s' % (rep['map'] or 'none', rep['verification']))
    if not x:
        L.append('exception: none recorded (a manual dump); all threads follow')
    else:
        name = x['name'] or 'unknown exception'
        L.append('exception: %s %s' % (x['code'], name))
        if 'access' in x:
            L.append('  access violation: %s at address %s' % (x['access'], x['target']))
        if 'fast_fail_code' in x:
            L.append('  fast-fail code: %d' % x['fast_fail_code'])
        L.append('  parameters: %s' % (' '.join(x['parameters']) or 'none'))
        L.append('crashing thread: %d' % x['thread_id'])
        L.append('address: %s' % x['address'])
        loc = rep['crash_address_location']
        where = {'game': 'game image', 'module': 'module', 'none': ''}[loc['kind']]
        L.append('location: %s%s' % (loc['label'], '  (%s%s)' % (where, ', function %s' % loc['function'] if loc['function'] else '') if where else ''))
        L.append('')
        regs = rep['registers']
        if regs:
            L.append('registers of the crashing thread:')
            order = ['rip', 'rsp', 'rbp', 'rax', 'rcx', 'rdx', 'rbx', 'rsi', 'rdi', 'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15', 'eflags']
            for i in range(0, len(order), 3):
                L.append('  ' + '  '.join('%-6s %s' % (k, regs[k]) for k in order[i:i + 3]))
        else:
            L.append('registers: the context record is not in the dump')
        L.append('')
        s = rep['stack']
        L.append('stack: tier "%s" (%s)' % (s['tier'], s.get('note') or ''))
        L.append('  ' + NOTE)
        L += render_entries(s['entries'])
    for t in rep.get('other_threads', []):
        L.append('')
        L.append('thread %d:' % t['thread_id'])
        if t['rip'] is None:
            L.append('  ' + t['note'])
            continue
        L.append('  at %s  %s' % (t['rip'], t['location']['label']))
        L += render_entries(t['stack'] or [], '  ')
        if t['stack'] is None:
            L.append('  ' + t['stack_note'])
    L.append('')
    L.append('summary: ' + rep['summary'])
    return '\n'.join(L)


def render_entries(entries, indent=''):
    if not entries:
        return [indent + '  (no return address found)']
    return [indent + '  +0x%04X  %-48s %s' % (e['offset_from_rsp'], e['label'], e['status'] + (' (%s)' % e['call'] if e['call'] else '')) for e in entries]


# ------------------------------------------------------------------------------------------------ commands

def open_dump(path, dbg):
    """The bytes of the dump: a mapped file, or the one dump in a zip. Returns (data, closer)."""
    if not os.path.isfile(path):
        raise CrashError('%s is not a file' % path)
    if path.lower().endswith('.zip'):
        with zipfile.ZipFile(path) as z:
            entries = [i for i in z.infolist() if i.filename.lower().endswith(('.dmp', '.mdmp'))]
            if len(entries) != 1:
                raise CrashError('%s must hold exactly one dump, it holds %d' % (path, len(entries)))
            if entries[0].file_size > dbg.MAX_INPUT:
                raise CrashError('the dump in %s is larger than %d bytes' % (path, dbg.MAX_INPUT))
            return z.read(entries[0]), lambda: None
    if os.path.getsize(path) == 0:
        raise CrashError('%s is empty' % path)
    f = open(path, 'rb')
    m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    return m, lambda: (m.close(), f.close())


def cmd_report(args):
    dbg = load_debugger()
    engine_map = None
    if args.map:
        if not os.path.isfile(args.map):
            raise CrashError('no engine map at %s' % args.map)
        try:
            engine_map = iw7_engine_map.Map(args.map)
            int(engine_map.meta['text_va']), int(engine_map.meta['text_bytes'])
        except (sqlite3.DatabaseError, KeyError, ValueError) as exc:
            raise CrashError('%s is not an engine map: %s' % (args.map, exc))
    reference = None
    if args.reference_root:
        ref = os.path.join(args.reference_root, 'unpacked-text.bin')
        if not os.path.isfile(ref):
            raise CrashError('no unpacked-text.bin in %s' % args.reference_root)
        try:
            import capstone  # noqa: F401
        except ImportError:
            raise CrashError('--reference-root needs the capstone package')
        reference = (iw7_engine_map.read_bytes(ref), int(engine_map.meta['text_va']) if engine_map else GAME_TEXT)
    if args.max_frames < 1:
        raise CrashError('--max-frames must be at least 1')
    data, close = open_dump(args.dump, dbg)
    try:
        dump = Dump(data, dbg)
        an = Analyzer(dump, engine_map, reference)
        rep = build_report(args, args.dump, dump, an)
    finally:
        if engine_map is not None:
            engine_map.db.close()
        close()
    print(json.dumps(rep, indent=1) if args.json else render(rep))
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('report', help='name the crash address and the stack of a dump')
    s.add_argument('dump')
    s.add_argument('--map')
    s.add_argument('--reference-root')
    s.add_argument('--all-threads', action='store_true')
    s.add_argument('--json', action='store_true')
    s.add_argument('--max-frames', type=int, default=40)
    s.set_defaults(fn=cmd_report)
    args = p.parse_args(argv)
    try:
        return args.fn(args)
    except (CrashError, ValueError, OSError, struct.error, zipfile.BadZipFile, sqlite3.DatabaseError) as exc:
        print('error: %s: %s' % (os.path.basename(args.dump), exc), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
