"""Frame cuts (a51): the overlay edits against the pinned sources, and the wiring of the two native sources.

Offline checks:
  - ops/frame-cuts/frame-cut-edits.json is well formed and every edit text has the number of matches it declares in the pinned file
    (needs a checkout of the pinned iw7-mod: IW7_NATIVE_ROOT or tools/iw7-mod-native; skipped without);
  - the opcode stub: the filter test comes before any register save, uses r15 (dead at that point) and rax (saved), a pop that cannot disturb the flags,
    and a jump straight to the original instructions; the slow path (pushad, exact map lookup) is unchanged;
  - every writer of the replace map marks the filter: replacefunc, and the cutscene overlay's redirect; the shutdown clear clears both;
  - G_LogPrintf keeps a fallback to the old write, and the component flushes once per server frame, at script shutdown and at exit;
  - the build copies the sources, applies the overlay after the debugger overlay, and the debugger overlay takes the cuts out before its comparison
    (the exports in product.json are checked by checks.ps1 itself; the prepared source workspace has no product.json).
"""
import json
import os
import re
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
EDITS = os.path.join(ROOT, 'ops', 'frame-cuts', 'frame-cut-edits.json')
PIN = 'cfca45b11ee14641945b9a264a95638387f48a4a'
EXT = 'src/client/component/gsc/script_extension.cpp'
GAME = 'src/client/game/game.cpp'
CON = 'src/client/component/console/console.cpp'
TER = 'src/client/component/console/terminal.cpp'
EXC = 'src/client/component/exception.cpp'
FFS = 'src/client/component/fastfiles.cpp'


def read(*path):
    with open(os.path.join(ROOT, *path), encoding='utf-8') as f:
        return f.read().replace('\r\n', '\n')


def pinned(path):
    for root in (os.environ.get('IW7_NATIVE_ROOT'), os.path.join(ROOT, 'tools', 'iw7-mod-native')):
        if root and os.path.isdir(os.path.join(root, '.git')):
            r = subprocess.run(['git', '-C', root, 'show', PIN + ':' + path], capture_output=True)
            if r.returncode == 0:
                return r.stdout.decode('utf-8').replace('\r\n', '\n')
    return None


SPEC = json.loads(read('ops', 'frame-cuts', 'frame-cut-edits.json'))


def edits(path):
    return [f for f in SPEC['files'] if f['path'] == path][0]['edits']


def applied(path, text):
    for e in edits(path):
        assert text.count(e['old']) == e['count'], (path, e['old'][:60])
        text = text.replace(e['old'], e['new'])
    return text


class Edits(unittest.TestCase):
    def test_shape(self):
        self.assertEqual(SPEC['schema'], 'iw7.frame-cut-edits/1')
        self.assertEqual(SPEC['pin'], PIN)
        self.assertEqual(sorted(f['path'] for f in SPEC['files']), sorted([EXT, GAME, CON, TER, EXC, FFS]))
        for f in SPEC['files']:
            for e in f['edits']:
                self.assertGreaterEqual(e['count'], 1)
                self.assertNotEqual(e['old'], e['new'])
                self.assertNotIn('\r', e['old'] + e['new'])

    def test_pinned_sources(self):
        checked = 0
        for f in SPEC['files']:
            text = pinned(f['path'])
            if text is None:
                continue
            checked += 1
            out = applied(f['path'], text)
            self.assertNotEqual(out, text)
        if not checked:
            self.skipTest('no checkout of the pinned iw7-mod (IW7_NATIVE_ROOT)')

    def test_stub_order(self):
        new = ''.join(e['new'] for e in edits(EXT))
        first = new.index('a.push(rax);')
        for needle in ('a.mov(rax, reinterpret_cast<std::uint64_t>(paris_vm_filter::table));', 'a.movzx(r15d, si);', 'a.cmp(byte_ptr(rax, r15), 0);',
                       'a.pop(rax);', 'a.je(end);', 'a.pushad64();'):
            self.assertIn(needle, new)
        order = [new.index(n) for n in ('a.push(rax);', 'a.mov(rax,', 'a.movzx(r15d, si);', 'a.cmp(byte_ptr(rax, r15), 0);', 'a.pop(rax);', 'a.je(end);', 'a.pushad64();')]
        self.assertEqual(order, sorted(order))
        self.assertEqual(first, order[0])
        # the filter is read before pushad64 saves anything, and nothing between push and pop touches the flags before the cmp is read
        self.assertNotIn('call_aligned', new[first:new.index('a.pushad64();')])

    def test_every_writer_marks_the_filter(self):
        ext = ''.join(e['new'] for e in edits(EXT))
        self.assertIn('vm_execute_hooks[what.u.codePosValue] = with.u.codePosValue;\n\t\t\t\tparis_vm_filter::mark(what.u.codePosValue);', ext)
        self.assertIn('vm_execute_hooks.clear();\n\t\t\t\t\tparis_vm_filter::clear();', ext)
        self.assertIn('paris_vm_filter::mark(from);', read('ops', 'Cutscene-Overlay.Core.ps1'))
        # nothing else of this repository writes the map
        for path in ('src/native', 'ops'):
            for dirpath, _, names in os.walk(os.path.join(ROOT, path)):
                for n in names:
                    if n.endswith(('.cpp', '.hpp', '.ps1', '.inc')):
                        text = read(os.path.relpath(os.path.join(dirpath, n), ROOT))
                        for m in re.finditer(r'vm_execute_hooks\[[^\]]*\]\s*=', text):
                            line = text[:m.start()].count('\n')
                            context = text[max(0, m.start() - 200):m.end() + 200]
                            self.assertIn('paris_vm_filter', context, (n, line))

    def test_log_fallback_and_flush(self):
        new = ''.join(e['new'] for e in edits(GAME))
        self.assertIn('if (!paris_log_stream::instance().append(file, line))\n\t\t{\n\t\t\tutils::io::write_file(file, line, true);', new)
        cpp = read('src', 'native', 'paris_log_stream.cpp')
        self.assertIn('scheduler::pipeline::server', cpp)
        self.assertIn('scripting::on_shutdown', cpp)
        self.assertIn('pre_destroy', cpp)
        self.assertIn('close_all()', cpp)
        hpp = read('src', 'native', 'paris_log_stream.hpp')
        self.assertIn('std::ios::binary | std::ios::out | std::ios::app', hpp)


    def test_console_writer_wiring(self):
        con = ''.join(e['new'] for e in edits(CON))
        ter = ''.join(e['new'] for e in edits(TER))
        # the printing thread checks rcon, then offers the line to the writer; the syscon window stays on the printing thread
        order = [con.index(n) for n in ('rcon::message_redirect(message)', '!syscon::is_enabled() && paris_console_writer::submit(type, message)', 'write_sinks(type, message, false);')]
        self.assertEqual(order, sorted(order))
        # the writer thread skips the rcon check (a line queued before an rcon command must not be sent to the rcon client) and keeps the log handle open
        self.assertIn('::terminal::dispatch_message_direct(type, message);', con)
        self.assertIn('!queued || !paris_console_writer::console_log_stream().append(', con)
        self.assertIn('void dispatch_message_queued(const int type, const std::string& message)', con)
        self.assertIn('int dispatch_message(const int type, const std::string& message)\n\t{\n\t\tif (rcon::message_redirect(message))', ter)
        self.assertIn('return dispatch_message_direct(type, message);', ter)
        direct = ter.index('int dispatch_message_direct')
        self.assertNotIn('rcon::message_redirect', ter[direct:ter.index('update();\n\t\treturn res;')])
        cpp = read('src', 'native', 'paris_console_writer.cpp')
        self.assertIn('console::dispatch_message_queued(type, message);', cpp)
        self.assertIn('paris-no-console-writer', cpp)
        self.assertIn('console_log_stream().flush()', cpp)
        # the crash path: the game's exception filter waits for the writer before it writes its dump; an unchanged console title is not sent again
        exc = ''.join(e['new'] for e in edits(EXC))
        self.assertLess(exc.index('wait_for_lines_on_crash();'), exc.index('write_minidump(exceptioninfo);'))
        self.assertIn('if (title == last_title)', con)


class UsermapBase(unittest.TestCase):
    """Studio gate G1: stock zones in usermaps/<map>/<map>.base load right before the map zone."""
    def test_stub_calls_loader_before_the_map_zone(self):
        new = ''.join(e['new'] for e in edits(FFS))
        self.assertLess(new.index('paris_usermap_base::load_before(parent_name'), new.index('Loading zone %s'))
        # a `nopatch` base zone loads with the custom flag (no patch_<zone>; the loader queues techsets_/cache_ by name), the others as the engine does
        self.assertIn('[&](const char* base_zone, const usermap_base::load_mode& mode)', new)
        self.assertIn('db_load_x_zone_hook.invoke<void>(base_zone, usermap_base::load_flags(zone_flags, mode, game::DB_ZONE_CUSTOM), is_base_map && paris_usermap_base::map_wins_value() != 2, failure_mode);', new)
        self.assertIn('#include "paris_usermap_base.hpp"', new)

    def test_usermap_patch_zone_lookup(self):
        # the client finds usermaps/<map>/patch_<map>.ff: the file lookup and the existence check both ask the policy, and the old text they replace is still there once
        es = edits(FFS)
        new = ''.join(e['new'] for e in es)
        self.assertIn('usermap_base::patch_zone_path(filename)', new)
        self.assertIn('usermap_base::patch_zone_path(name)', new)
        self.assertIn('return create_file_a(patch_zone);', new)
        self.assertTrue(any(e['old'].strip() == "const auto ext = filename.find_last_of('.');" and e['count'] == 1 for e in es))

    def test_loader_rules(self):
        hpp = read('src', 'native', 'paris_usermap_base.hpp')
        self.assertIn('usermap_base::valid_zone_name(zone_name)', hpp)
        self.assertNotIn('get_current_usermap', hpp)
        self.assertIn('fastfiles::exists(zone.name, true)', hpp)
        self.assertIn('not found, skipped', hpp)
        self.assertIn('usermaps/%s/%s.base', hpp)
        self.assertIn('usermap_base::companion_zones(zone.name)', hpp)
        self.assertLess(hpp.index('usermap_base::companion_zones(zone.name)'), hpp.index('load(names.back().data(), mode)'))

    def test_build_wiring(self):
        text = read('ops', 'Build-Voice.ps1')
        for name in ("'paris_usermap_base.hpp'", "'usermap_base_policy.hpp'", 'usermap_base_test.cpp', "Remove-IW7FrameCutText 'src/client/component/fastfiles.cpp'", "Add-IW7FrameCutText 'src/client/component/fastfiles.cpp'"):
            self.assertIn(name, text)

    def test_pinned_fastfiles(self):
        text = pinned(FFS)
        if text is None:
            self.skipTest('no checkout of the pinned iw7-mod')
        out = applied(FFS, text)
        self.assertIn('paris_usermap_base::load_before', out)


class Wiring(unittest.TestCase):
    def test_build(self):
        text = read('ops', 'Build-Voice.ps1')
        for name in ("'paris_vm_filter.hpp'", "'paris_log_stream.hpp'", "'paris_log_stream.cpp'", "'paris_console_writer.hpp'", "'paris_console_writer.cpp'"):
            self.assertIn(name, text)
        self.assertIn('vm_filter_test.cpp', text)
        self.assertIn('log_stream_test.cpp', text)
        self.assertIn('console_writer_test.cpp', text)
        self.assertLess(text.index('Apply-DebuggerOverlay.ps1" -NativeRoot'), text.index('Apply-FrameCutsOverlay.ps1" -NativeRoot'))
        self.assertLess(text.index('Apply-FrameCutsOverlay.ps1" -NativeRoot'), text.index('Add-IW7CutsceneOverlay $root'))
        self.assertLess(text.index('Copy-Item -LiteralPath @($nativeSources'), text.index('Apply-FrameCutsOverlay.ps1" -NativeRoot'))
        self.assertIn('$manifest.FrameCutsOverlay', text)

    def test_debugger_overlay_takes_the_cuts_out_before_it_compares(self):
        text = read('ops', 'Apply-DebuggerOverlay.ps1')
        self.assertIn('FrameCuts.Core.ps1', text)
        self.assertLess(text.index('Remove-IW7FrameCutText $Relative $current $Commit'), text.index('if ($current -ne $base'))


if __name__ == '__main__':
    unittest.main()
