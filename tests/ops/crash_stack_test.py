"""Unit tests for ops/engine-map/iw7_crash.py on a hand-written minidump, a synthetic engine map and synthetic code bytes."""
import contextlib
import gc
import importlib.util
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest
import warnings
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def load(name, rel):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


emt = load('engine_map_test_helpers', 'tests/ops/engine_map_test.py')
em = emt.em
crash = load('iw7_crash_under_test', 'ops/engine-map/iw7_crash.py')

A, B, E = emt.A, emt.B, emt.E
BASE = emt.BASE
F = emt.TEXT_VA + 0x500                 # a function with an indirect call and a register call, assembled here
SLOT = emt.RDATA_VA + 0x180
GAME_MODULE = ('game.exe', BASE, 0x1500000)
SYS_MODULE = ('system.dll', 0x7FFB00000000, 0x200000)
SYS_A, SYS_B, SYS_C = (SYS_MODULE[1] + o for o in (0x1234, 0x2000, 0x10))
STACK_BASE = 0x000000A000000000
STACK2_BASE = 0x000000A100000000
CRASH_RIP = A + 0x0C                    # Foo+0xC in the synthetic map
CRASH_RSP = STACK_BASE


def sections():
    """The sections of engine_map_test plus the function F, with a directory entry for it."""
    text, rdata, pdata = emt.make_sections()
    text = bytearray(text)
    code = bytearray(b'\x48\x83\xEC\x28')                                              # sub rsp, 0x28
    code += b'\xFF\x15' + struct.pack('<i', SLOT - (F + len(code) + 6))              # call [rip+x]   F+4, returns to F+0x0A
    code += b'\xFF\xD0'                                                                # call rax       F+0x0A, returns to F+0x0C
    code += b'\x48\x83\xC4\x28' + b'\xC3'                                              # add rsp, 0x28 ; ret
    assert len(code) == 0x11
    text[F - emt.TEXT_VA:F - emt.TEXT_VA + len(code)] = code
    entries = [struct.unpack_from('<III', pdata, i) for i in range(0, len(pdata) - 12, 12)]
    entries.append((F - BASE, F - BASE + 0x11, emt.RDATA_VA - BASE))
    pdata = b''.join(struct.pack('<III', *e) for e in sorted(entries)) + struct.pack('<III', 0, 0, 0)
    return bytes(text), bytes(rdata), pdata


NON_CALL = F + 0x10                      # points into code, preceded by "add rsp, 0x28": not a return address
RET_DIRECT = B + 0x10                    # B calls C at B+0x0B and B+0x10 (E8 rel32): returns to B+0x10 and B+0x15
RET_DIRECT2 = A + 0x0E                   # A calls LEAF at A+9
RET_INDIRECT = F + 0x0A                  # after call [rip+x]
RET_REGISTER = F + 0x0C                  # after call rax


class Builder:
    """Writes a minidump: header, stream directory, then the streams and the memory they point at."""

    def __init__(self, streams):
        self.count = streams
        self.start = 32 + 12 * streams
        self.body = bytearray()
        self.dir = []

    def put(self, data):
        while len(self.body) % 8:
            self.body += b'\0'
        rva = self.start + len(self.body)
        self.body += data
        return rva

    def stream(self, kind, data):
        self.dir.append((kind, len(data), self.put(data)))

    def finish(self):
        head = b'MDMP' + struct.pack('<IIIII', 0xA793, self.count, 32, 0, 0) + struct.pack('<Q', 0)
        assert len(head) == 32
        directory = b''.join(struct.pack('<III', *d) for d in self.dir) + b'\0' * 12 * (self.count - len(self.dir))
        return head + directory + bytes(self.body)


def mdstring(text):
    raw = text.encode('utf-16-le')
    return struct.pack('<I', len(raw)) + raw + b'\0\0'


def context(rip, rsp, rbp=0x1122, rax=0x3344):
    c = bytearray(1232)
    struct.pack_into('<I', c, 48, 0x10000B)
    struct.pack_into('<I', c, 68, 0x10246)
    for off, v in ((120, rax), (152, rsp), (160, rbp), (248, rip)):
        struct.pack_into('<Q', c, off, v)
    return bytes(c)


def stack_bytes(values, size=0x100):
    raw = b''.join(struct.pack('<Q', v) for v in values)
    return raw + b'\0' * (size - len(raw))


CRASH_STACK = [0x1111, RET_DIRECT, NON_CALL, RET_INDIRECT, SYS_A, SYS_B, RET_REGISTER, 0x7FF000000, RET_DIRECT2, SYS_C]
OTHER_STACK = [0, B + 0x15, 0x2222, F + 0x0A, SYS_C]


def make_dump(exception=True, rip=CRASH_RIP, memory_info=False, second_thread=True, code=0xC0000005, parameters=(1, 0x4D10)):
    n = 4 + (1 if exception else 0) + (1 if memory_info else 0)
    b = Builder(n)
    stack1 = b.put(stack_bytes(CRASH_STACK))
    stack2 = b.put(stack_bytes(OTHER_STACK))
    ctx1 = b.put(context(0x5555, 0x6666))                       # the thread list holds a different context than the exception
    ctx2 = b.put(context(SYS_MODULE[1] + 0x500, STACK2_BASE, rax=0x77))
    threads = [struct.pack('<IIIIQ', 100, 0, 0, 0, 0) + struct.pack('<QII', STACK_BASE, 0x100, stack1) + struct.pack('<II', 1232, ctx1)]
    if second_thread:
        threads.append(struct.pack('<IIIIQ', 200, 0, 0, 0, 0) + struct.pack('<QII', STACK2_BASE, 0x100, stack2) + struct.pack('<II', 1232, ctx2))
    b.stream(3, struct.pack('<I', len(threads)) + b''.join(threads))
    mods = b''
    for name, base, size in (GAME_MODULE, SYS_MODULE):
        mods += struct.pack('<QIIII', base, size, 0, 0, b.put(mdstring(name))) + b'\0' * 52 + struct.pack('<II', 0, 0) + b'\0' * 24
    b.stream(4, struct.pack('<I', 2) + mods)
    b.stream(5, struct.pack('<I', 0))
    if exception:
        ctx = b.put(context(rip, CRASH_RSP))
        record = struct.pack('<IIQQII', code, 0, 0, rip, len(parameters), 0) + struct.pack('<15Q', *(list(parameters) + [0] * 15)[:15])
        b.stream(6, struct.pack('<II', 100, 0) + record + struct.pack('<II', 1232, ctx))
    if memory_info:
        def region(base, size, protect):
            return struct.pack('<QQIIQIIII', base, base, protect, 0, size, 0x1000, protect, 0x1000000, 0)
        regions = region(0, GAME_MODULE[1], 0x40) + region(GAME_MODULE[1], GAME_MODULE[2], 0x40) + region(SYS_MODULE[1], 0x1000, 0x02) + region(SYS_MODULE[1] + 0x1000, 0x1000, 0x20)
        b.stream(16, struct.pack('<IIQ', 16, 48, 4) + regions)
    return b.finish()


class CrashStackTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        warnings.simplefilter('ignore', ResourceWarning)
        cls.tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        cls.addClassCleanup(lambda: (gc.collect(), cls.tmp.cleanup()))
        d = Path(cls.tmp.name)
        cls.ref = d / 'ref'
        cls.ref.mkdir()
        for k, v in zip(('text', 'rdata', 'pdata'), sections()):
            (cls.ref / ('unpacked-%s.bin' % k)).write_bytes(v)
        cls.map = str(d / 'map.sqlite')
        with contextlib.redirect_stdout(io.StringIO()):
            rc = em.main(['build', '--db', cls.map, '--reference-root', str(cls.ref), '--workers', '1'])
        assert rc == 0
        cls.dir = d
        cls.dump = d / 'crash.dmp'
        cls.dump.write_bytes(make_dump())

    def run_tool(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = crash.main(list(argv))
        return rc, out.getvalue(), err.getvalue()

    def report(self, dump=None, *extra, full=True):
        args = ['report', str(dump or self.dump), '--json']
        if full:
            args += ['--map', self.map, '--reference-root', str(self.ref)]
        rc, out, err = self.run_tool(*args, *extra)
        self.assertEqual((rc, err), (0, ''))
        return json.loads(out)

    def labels(self, rep):
        return {e['address']: e for e in rep['stack']['entries']}

    # exception and place
    def test_exception_is_decoded(self):
        x = self.report()['exception']
        self.assertEqual((x['code'], x['name'], x['access'], x['target'], x['thread_id']), ('0xC0000005', 'access violation', 'write', '0x4D10', 100))
        self.assertEqual(x['address'], '0x%X' % CRASH_RIP)

    def test_other_exception_codes(self):
        for code, name, params in ((0xC00000FD, 'stack overflow', ()), (0x80000003, 'breakpoint', (0,)), (0xC0000409, 'fail-fast', (7,)),
                                   (0xE06D7363, 'C++ exception', (0x19930520,)), (0xC0000094, None, ())):
            path = self.dir / ('x%X.dmp' % code)
            path.write_bytes(make_dump(code=code, parameters=params))
            x = self.report(path)['exception']
            self.assertEqual((x['code'], x['name']), ('0x%08X' % code, name))
        self.assertEqual(self.report(self.dir / 'xC0000409.dmp')['exception']['fast_fail_code'], 7)
        for param, word in ((0, 'read'), (8, 'execute')):
            path = self.dir / ('av%d.dmp' % param)
            path.write_bytes(make_dump(parameters=(param, 0x10)))
            self.assertEqual(self.report(path)['exception']['access'], word)

    def test_crash_address_named_through_the_map(self):
        rep = self.report()
        loc = rep['crash_address_location']
        self.assertEqual((loc['kind'], loc['label'], loc['function'], loc['offset']), ('game', 'sub_%X+0xC' % A, '0x%X' % A, 0x0C))
        rc, out, err = self.run_tool('report', str(self.dump), '--map', self.map)
        self.assertIn('location: sub_%X+0xC' % A, out)
        self.assertIn('access violation: write at address 0x4D10', out)

    def test_crash_address_in_another_module(self):
        path = self.dir / 'other.dmp'
        path.write_bytes(make_dump(rip=SYS_A))
        loc = self.report(path)['crash_address_location']
        self.assertEqual((loc['kind'], loc['label'], loc['module']), ('module', 'system.dll+0x1234', 'system.dll'))
        path.write_bytes(make_dump(rip=0x1000))
        loc = self.report(path)['crash_address_location']
        self.assertEqual((loc['kind'], loc['label']), ('none', 'not in any module'))

    def test_game_address_without_a_function_and_without_a_map(self):
        path = self.dir / 'gap.dmp'
        path.write_bytes(make_dump(rip=emt.GAP + 1))
        self.assertEqual(self.report(path)['crash_address_location']['label'], 'game+0x%X' % (emt.GAP + 1 - BASE))
        rep = self.report(full=False)
        self.assertEqual(rep['crash_address_location']['label'], 'game.exe+0x%X' % (CRASH_RIP - BASE))
        self.assertIsNone(rep['map'])

    def test_registers_come_from_the_exception_context(self):
        regs = self.report()['registers']
        self.assertEqual((regs['rip'], regs['rsp'], regs['rbp'], regs['rax']), ('0x%X' % CRASH_RIP, '0x%X' % CRASH_RSP, '0x1122', '0x3344'))
        rc, out, err = self.run_tool('report', str(self.dump))
        self.assertIn('rsp    0x%X' % CRASH_RSP, out)

    # the stack
    def test_return_addresses_are_verified_with_the_reference_bytes(self):
        rep = self.report()
        by = self.labels(rep)
        self.assertEqual(rep['stack']['tier'], 'return addresses')
        kinds = [(e['offset_from_rsp'], e['status'], e['call']) for e in rep['stack']['entries']]
        self.assertEqual(kinds, [(0x08, 'verified call', 'direct'), (0x18, 'verified call', 'indirect'), (0x20, 'unverified', None),
                                 (0x30, 'verified call', 'indirect'), (0x40, 'verified call', 'direct'), (0x48, 'unverified', None)])
        self.assertEqual(by['0x%X' % RET_DIRECT]['label'], 'sub_%X+0x10' % B)
        self.assertEqual(by['0x%X' % RET_DIRECT]['call_site'], '0x%X' % (RET_DIRECT - 5))
        self.assertEqual(by['0x%X' % RET_INDIRECT]['call_site'], '0x%X' % (RET_INDIRECT - 6))        # FF 15 rel32
        self.assertEqual(by['0x%X' % RET_REGISTER]['call_site'], '0x%X' % (RET_REGISTER - 2))        # FF D0
        self.assertEqual(by['0x%X' % RET_INDIRECT]['label'], 'sub_%X+0xA' % F)

    def test_a_value_in_code_that_is_not_after_a_call_is_dropped(self):
        rep = self.report()
        self.assertNotIn('0x%X' % NON_CALL, self.labels(rep))
        self.assertNotIn('0x7FF000000', self.labels(rep))
        self.assertNotIn('0x1111', self.labels(rep))

    def test_without_reference_root_only_direct_calls_are_verified(self):
        rc, out, err = self.run_tool('report', str(self.dump), '--map', self.map, '--json')
        rep = json.loads(out)
        verified = [e['address'] for e in rep['stack']['entries'] if e['status'] == 'verified call']
        self.assertEqual(verified, ['0x%X' % RET_DIRECT, '0x%X' % RET_DIRECT2])
        self.assertIn('direct call', rep['verification'])
        self.assertIn('indirect calls cannot be verified', rep['verification'])
        rc, text, err = self.run_tool('report', str(self.dump), '--map', self.map)
        self.assertIn('indirect calls cannot be verified', text)

    def test_stale_value_in_another_module_is_unverified_and_one_per_row(self):
        rep = self.report()
        sys_entries = [e for e in rep['stack']['entries'] if e['module'] == 'system.dll']
        self.assertEqual([(e['address'], e['status'], e['label']) for e in sys_entries],
                         [('0x%X' % SYS_A, 'unverified', 'system.dll+0x1234'), ('0x%X' % SYS_C, 'unverified', 'system.dll+0x10')])   # SYS_B follows SYS_A directly

    def test_without_map_or_reference_game_values_are_unverified_modules(self):
        rep = self.report(full=False)
        self.assertIn('none', rep['verification'])
        self.assertTrue(all(e['status'] == 'unverified' for e in rep['stack']['entries']))
        self.assertEqual(rep['stack']['entries'][0]['label'], 'game.exe+0x%X' % (RET_DIRECT - BASE))
        self.assertIn('no verified return address found', rep['summary'])

    def test_memory_info_drops_unexecutable_module_addresses(self):
        path = self.dir / 'info.dmp'
        path.write_bytes(make_dump(memory_info=True))
        rep = self.report(path)
        # system.dll: first page read-only (SYS_C), second page code (SYS_A), nothing known beyond (SYS_B)
        self.assertEqual([e['address'] for e in rep['stack']['entries'] if e['module'] == 'system.dll'], ['0x%X' % SYS_A])
        self.assertEqual(len(rep['stack']['entries']), 5)

    def test_max_frames_limits_the_list(self):
        rep = self.report(None, '--max-frames', '2')
        self.assertEqual(len(rep['stack']['entries']), 2)
        self.assertEqual(self.run_tool('report', str(self.dump), '--max-frames', '0')[0], 2)

    def test_the_text_says_what_the_list_is(self):
        rc, out, err = self.run_tool('report', str(self.dump), '--map', self.map, '--reference-root', str(self.ref))
        self.assertEqual(rc, 0)
        self.assertIn('scanned from the stack, not unwound', out)
        self.assertIn('earlier calls', out)
        self.assertIn('verified call (direct)', out)
        self.assertIn('unverified', out)

    def test_summary_line(self):
        rep = self.report()
        self.assertEqual(rep['summary'], 'crash access violation (write) at sub_%X+0xC, called from sub_%X+0x10, sub_%X+0xA' % (A, B, F))
        rc, out, err = self.run_tool('report', str(self.dump), '--map', self.map, '--reference-root', str(self.ref))
        self.assertEqual(out.splitlines()[-1], 'summary: ' + rep['summary'])

    # threads
    def test_all_threads(self):
        rc, out, err = self.run_tool('report', str(self.dump), '--map', self.map, '--reference-root', str(self.ref))
        self.assertNotIn('thread 200', out)
        rep = self.report(None, '--all-threads')
        self.assertEqual(len(rep['other_threads']), 1)
        t = rep['other_threads'][0]
        self.assertEqual((t['thread_id'], t['rip'], t['location']['label']), (200, '0x%X' % (SYS_MODULE[1] + 0x500), 'system.dll+0x500'))
        self.assertEqual([(e['offset_from_rsp'], e['status'], e['label']) for e in t['stack']],
                         [(0x08, 'verified call', 'sub_%X+0x15' % B), (0x18, 'verified call', 'sub_%X+0xA' % F), (0x20, 'unverified', 'system.dll+0x10')])
        rc, out, err = self.run_tool('report', str(self.dump), '--map', self.map, '--reference-root', str(self.ref), '--all-threads')
        self.assertIn('thread 200:', out)

    def test_other_threads_are_limited_to_five_entries(self):
        values = [B + 0x15] * 8
        b = Builder(3)
        stack = b.put(stack_bytes(values))
        ctx = b.put(context(SYS_A, STACK2_BASE))
        b.stream(3, struct.pack('<I', 1) + struct.pack('<IIIIQ', 7, 0, 0, 0, 0) + struct.pack('<QII', STACK2_BASE, 0x100, stack) + struct.pack('<II', 1232, ctx))
        b.stream(4, struct.pack('<I', 2) + b''.join(struct.pack('<QIIII', base, size, 0, 0, b.put(mdstring(name))) + b'\0' * 52 + struct.pack('<II', 0, 0) + b'\0' * 24
                                                      for name, base, size in (GAME_MODULE, SYS_MODULE)))
        b.stream(5, struct.pack('<I', 0))
        path = self.dir / 'five.dmp'
        path.write_bytes(b.finish())
        rep = self.report(path)
        self.assertIsNone(rep['exception'])
        self.assertEqual(len(rep['other_threads'][0]['stack']), 5)

    def test_dump_without_exception_stream_still_reports_threads(self):
        path = self.dir / 'manual.dmp'
        path.write_bytes(make_dump(exception=False))
        rep = self.report(path)
        self.assertIsNone(rep['exception'])
        self.assertEqual([t['thread_id'] for t in rep['other_threads']], [100, 200])
        self.assertEqual(rep['other_threads'][0]['rip'], '0x5555')
        self.assertIn('without an exception record', rep['summary'])
        rc, out, err = self.run_tool('report', str(path), '--map', self.map)
        self.assertEqual(rc, 0)
        self.assertIn('exception: none recorded', out)
        self.assertIn('thread 200:', out)

    # output forms
    def test_json_agrees_with_text(self):
        rep = self.report()
        rc, out, err = self.run_tool('report', str(self.dump), '--map', self.map, '--reference-root', str(self.ref))
        for e in rep['stack']['entries']:
            self.assertRegex(out, r'\+0x%04X  %s\s+%s' % (e['offset_from_rsp'], e['label'].replace('+', r'\+'), e['status']))
        self.assertIn(rep['exception']['code'], out)
        self.assertIn(rep['crash_address_location']['label'], out)
        self.assertEqual(rep['schema'], 'iw7.crash-stack/1')

    def test_zip_holding_the_dump(self):
        path = self.dir / 'crash.zip'
        with zipfile.ZipFile(path, 'w') as z:
            z.writestr('crash.dmp', make_dump())
            z.writestr('info.txt', 'IW7-Mod Crash Dump')
        zipped = self.report(path)
        plain = self.report()
        zipped['dump'] = plain['dump']
        self.assertEqual(zipped, plain)
        two = self.dir / 'two.zip'
        with zipfile.ZipFile(two, 'w') as z:
            z.writestr('a.dmp', make_dump())
            z.writestr('b.dmp', make_dump())
        rc, out, err = self.run_tool('report', str(two))
        self.assertEqual((rc, out), (2, ''))
        self.assertIn('exactly one dump', err)

    # errors
    def test_truncated_or_invalid_input_exits_2_with_a_message(self):
        good = make_dump()
        cases = {'tiny.dmp': good[:10], 'cut.dmp': good[:len(good) - 40], 'half.dmp': good[:len(good) // 2], 'text.dmp': b'not a dump at all, just text ' * 4,
                 'empty.dmp': b''}
        for name, data in cases.items():
            path = self.dir / name
            path.write_bytes(data)
            rc, out, err = self.run_tool('report', str(path), '--map', self.map)
            self.assertEqual((rc, out), (2, ''), name)
            self.assertTrue(err.startswith('error: %s' % name), err)
            self.assertNotIn('Traceback', err)
        rc, out, err = self.run_tool('report', str(self.dir / 'missing.dmp'))
        self.assertEqual(rc, 2)
        self.assertIn('not a file', err)

    def test_bad_zip_and_bad_inputs_exit_2(self):
        bad = self.dir / 'bad.zip'
        bad.write_bytes(b'PK\x03\x04 broken')
        self.assertEqual(self.run_tool('report', str(bad))[0], 2)
        self.assertEqual(self.run_tool('report', str(self.dump), '--map', str(self.dir / 'nope.sqlite'))[0], 2)
        notmap = self.dir / 'notmap.sqlite'
        notmap.write_bytes(b'this is not a database' * 10)
        rc, out, err = self.run_tool('report', str(self.dump), '--map', str(notmap))
        self.assertEqual((rc, out), (2, ''))
        rc, out, err = self.run_tool('report', str(self.dump), '--reference-root', str(self.dir))
        self.assertEqual(rc, 2)
        self.assertIn('unpacked-text.bin', err)

    def test_stack_missing_from_the_dump_is_said_plainly(self):
        data = bytearray(make_dump())
        # move the stack of the first thread out of the dump: its descriptor start no longer holds RSP
        for t_off in range(len(data) - 8):
            if data[t_off:t_off + 8] == struct.pack('<Q', STACK_BASE) and data[t_off + 8:t_off + 12] == struct.pack('<I', 0x100):
                data[t_off:t_off + 8] = struct.pack('<Q', STACK_BASE + 0x10000)
                break
        path = self.dir / 'nostack.dmp'
        path.write_bytes(bytes(data))
        rep = self.report(path)
        self.assertEqual(rep['stack']['entries'], [])
        self.assertIn('not in the dump', rep['stack']['note'])
        self.assertIn('no verified return address found', rep['summary'])


if __name__ == '__main__':
    unittest.main()
