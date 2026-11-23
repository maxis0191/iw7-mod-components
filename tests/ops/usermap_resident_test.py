"""Resident base zone (Studio loop, L3): `<zone> resident` in usermaps/<map>/<map>.base loads the stock zone once per game process.

Offline checks (no game, no build):
  - the fastfiles.cpp edit hands the loader a load_mode and builds the zone flags with usermap_base::load_flags, still before the map zone is logged;
  - the loader claims a resident zone before it loads it, skips it (and its companions) when it is held, and marks the permanent flag for the zone and its companions;
  - the policy carries the option in the parser, the flag value of DB_ZONE_PERMANENT and the held-zone set; the native test covers them;
  - the permanent flag is the engine's own value (database.hpp of the pinned client, when a checkout is available);
  - the two `nopatch` / `resident` options keep their old behaviour when absent (a zone without options is loaded exactly as before: no permanent bit, no claim).
"""
import json
import os
import re
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
FFS = 'src/client/component/fastfiles.cpp'
PIN = 'cfca45b11ee14641945b9a264a95638387f48a4a'


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
FF_EDITS = [f for f in SPEC['files'] if f['path'] == FFS][0]['edits']
HPP = read('src', 'native', 'paris_usermap_base.hpp')
POL = read('src', 'native', 'usermap_base_policy.hpp')
NATIVE_TEST = read('tests', 'native', 'usermap_base_test.cpp')


class FastfilesEdit(unittest.TestCase):
    def new_text(self):
        return ''.join(e['new'] for e in FF_EDITS)

    def test_the_callback_takes_a_mode_and_the_flags_come_from_the_policy(self):
        new = self.new_text()
        self.assertIn('[&](const char* base_zone, const usermap_base::load_mode& mode)', new)
        self.assertIn('db_load_x_zone_hook.invoke<void>(base_zone, usermap_base::load_flags(zone_flags, mode, game::DB_ZONE_CUSTOM), is_base_map, failure_mode);', new)
        self.assertNotIn('bool custom', new)
        self.assertLess(new.index('paris_usermap_base::load_before(parent_name'), new.index('Loading zone %s'))

    def test_every_old_text_still_has_its_declared_count_in_the_pinned_file(self):
        text = pinned(FFS)
        if text is None:
            self.skipTest('no checkout of the pinned iw7-mod (IW7_NATIVE_ROOT)')
        for e in FF_EDITS:
            self.assertEqual(text.count(e['old']), e['count'], e['old'][:60])
            text = text.replace(e['old'], e['new'])
        self.assertIn('usermap_base::load_flags(zone_flags, mode, game::DB_ZONE_CUSTOM)', text)

    def test_the_permanent_flag_is_the_engines(self):
        db = pinned('src/client/game/types/database.hpp')
        if db is None:
            self.skipTest('no checkout of the pinned iw7-mod (IW7_NATIVE_ROOT)')
        self.assertRegex(db, r'DB_ZONE_PERMANENT\s*=\s*0x1,')
        self.assertRegex(db, r'DB_ZONE_GAME\s*=\s*0x80,')
        m = re.search(r'constexpr int zone_flag_permanent = (0x[0-9a-f]+);', POL)
        self.assertIsNotNone(m)
        self.assertEqual(int(m.group(1), 16), 1)


class Loader(unittest.TestCase):
    def test_a_resident_zone_is_claimed_before_it_is_loaded_and_skipped_when_held(self):
        a = HPP.index('zone.resident && !resident_zones().claim(zone.name)')
        b = HPP.index('load(names.back().data(), mode);')
        self.assertLess(a, b)
        self.assertIn('is resident, not loaded again', HPP)
        skip = HPP[a:HPP.index('continue;', a)]
        self.assertNotIn('load(', skip)

    def test_the_permanent_flag_goes_to_the_zone_and_its_companions(self):
        self.assertIn('mode.permanent = zone.resident;', HPP)
        self.assertIn('companion_mode.permanent = zone.resident;', HPP)
        self.assertIn('load(names.back().data(), companion_mode);', HPP)
        self.assertLess(HPP.index('load(names.back().data(), companion_mode);'), HPP.index('load(names.back().data(), mode);'))

    def test_a_zone_without_options_loads_as_before(self):
        # no option: no claim (the claim is only asked when resident), custom and permanent both false
        self.assertIn('usermap_base::load_mode mode;\n\t\t\tmode.custom = zone.no_patch;\n\t\t\tmode.permanent = zone.resident;', HPP)
        self.assertIn('zone.resident && !resident_zones()', HPP)
        self.assertRegex(POL, r'struct load_mode\s*\{\s*bool custom = false;[^}]*bool permanent = false;')
        self.assertIn('static usermap_base::resident_set zones;', HPP)

    def test_the_held_set_lives_for_the_process_not_the_level(self):
        # a function-local static of an inline function: one object for the whole executable, never cleared by a level change
        self.assertNotIn('release_all', HPP)

    def test_only_the_not_found_check_comes_before_the_claim(self):
        a = HPP.index('fastfiles::exists(zone.name, true)')
        b = HPP.index('resident_zones().claim')
        self.assertLess(a, b)          # a zone that is not there is never claimed (it would then never be loaded once it exists)


class Policy(unittest.TestCase):
    def test_options_are_parsed_in_any_order_each_once(self):
        self.assertIn('option == "resident"', POL)
        self.assertIn('option == "nopatch" && !e.no_patch', POL)
        self.assertIn('zone.resident = zone.resident || e.resident;', POL)

    def test_native_test_covers_the_new_rules(self):
        for needle in ('cp_town nopatch resident', 'res[1].resident && res[1].no_patch', 'rej3.size() == 3', 'usermap_base::load_flags(0x80u, perm, custom_bit) == 0x81u',
                       'held.claim("cp_zmb")', '!held.claim("cp_zmb") && held.size() == 1', 'held.release_all();'):
            self.assertIn(needle, NATIVE_TEST)

    def test_build_runs_the_native_test(self):
        self.assertIn('usermap_base_test.cpp', read('ops', 'Build-Voice.ps1'))


if __name__ == '__main__':
    unittest.main()
