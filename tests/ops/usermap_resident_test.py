"""Resident base zone (Studio loop, L3): `<zone> resident` in usermaps/<map>/<map>.base loads the stock zone once per game process.

Offline checks (no game, no build):
  - the fastfiles.cpp edit hands the loader a load_mode and builds the zone flags with usermap_base::load_flags, still before the map zone is logged;
  - the loader asks the engine's zone table (not a list of its own) before it loads a resident zone, skips it when the table holds it, and gives the permanent flag
    alone to the zone and its companions (a zone without options loads exactly as before: no permanent bit, the table is not asked);
  - the policy carries the option in the parser, the flag value of DB_ZONE_PERMANENT, the zone-name rule and the table size; the native test covers them;
  - the permanent flag and the zone-table accessors are the engine's own (the pinned client's database.hpp and symbols.hpp, when a checkout is available).
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

    def test_the_permanent_flag_and_the_zone_table_are_the_engines(self):
        db = pinned('src/client/game/types/database.hpp')
        sym = pinned('src/client/game/symbols.hpp')
        if db is None or sym is None:
            self.skipTest('no checkout of the pinned iw7-mod (IW7_NATIVE_ROOT)')
        self.assertRegex(db, r'DB_ZONE_PERMANENT\s*=\s*0x1,')
        self.assertRegex(db, r'DB_ZONE_GAME\s*=\s*0x80,')
        self.assertIn('DB_Zones_GetZoneNameFromIndex{0x1403BC410}', sym)
        self.assertIn('DB_Zones_IsValidZoneIndex{0x1403BC730}', sym)
        m = re.search(r'constexpr int zone_flag_permanent = (0x[0-9a-f]+);', POL)
        self.assertIsNotNone(m)
        self.assertEqual(int(m.group(1), 16), 1)


class Loader(unittest.TestCase):
    def test_a_resident_zone_is_skipped_when_the_engine_holds_it_and_loaded_otherwise(self):
        a = HPP.index('zone.resident && zone_loaded(zone.name.data())')
        b = HPP.index('load(names.back().data(), mode);')
        self.assertLess(a, b)
        self.assertIn('is resident, not loaded again', HPP)
        skip = HPP[a:HPP.index('continue;', a)]
        self.assertNotIn('load(', skip)

    def test_the_engines_zone_table_is_the_truth_not_a_list_of_our_own(self):
        body = HPP[HPP.index('inline bool zone_loaded'):HPP.index('inline void load_before')]
        self.assertIn('game::DB_Zones_IsValidZoneIndex(slot)', body)
        self.assertIn('usermap_base::same_zone_name(game::DB_Zones_GetZoneNameFromIndex(slot), name)', body)
        self.assertIn('slot < usermap_base::zone_slots', body)
        self.assertNotIn('static', body)                 # no process-wide list that could say a freed zone is still there
        self.assertIn('#include "game/game.hpp"', HPP)

    def test_the_permanent_flag_goes_to_the_zone_and_its_companions(self):
        self.assertIn('mode.permanent = zone.resident;', HPP)
        self.assertIn('companion_mode.permanent = zone.resident;', HPP)
        self.assertIn('load(names.back().data(), companion_mode);', HPP)
        self.assertLess(HPP.index('load(names.back().data(), companion_mode);'), HPP.index('load(names.back().data(), mode);'))

    def test_a_zone_without_options_loads_as_before(self):
        # no option: the zone table is not asked (`resident` is tested first), custom and permanent both false
        self.assertIn('usermap_base::load_mode mode;\n\t\t\tmode.custom = zone.no_patch;\n\t\t\tmode.permanent = zone.resident;', HPP)
        self.assertIn('zone.resident && zone_loaded(', HPP)
        self.assertRegex(POL, r'struct load_mode\s*\{\s*bool custom = false;[^}]*bool permanent = false;')

    def test_a_zone_that_is_not_there_is_never_asked_about(self):
        a = HPP.index('fastfiles::exists(zone.name, true)')
        b = HPP.index('zone_loaded(zone.name.data())')
        self.assertLess(a, b)


class Policy(unittest.TestCase):
    def test_options_are_parsed_in_any_order_each_once(self):
        self.assertIn('option == "resident"', POL)
        self.assertIn('option == "nopatch" && !e.no_patch', POL)
        self.assertIn('zone.resident = zone.resident || e.resident;', POL)

    def test_a_resident_zone_carries_the_permanent_flag_alone(self):
        body = POL[POL.index('inline unsigned int load_flags'):]
        body = body[:body.index('}')]
        self.assertIn('mode.permanent ? static_cast<unsigned int>(zone_flag_permanent) : zone_flags', body)

    def test_native_test_covers_the_new_rules(self):
        for needle in ('cp_town nopatch resident', 'res[1].resident && res[1].no_patch', 'rej3.size() == 3', 'usermap_base::load_flags(0x80u, perm, custom_bit) == 0x1u',
                       'usermap_base::same_zone_name("cp_zmb", "CP_ZMB")', 'slots == 373'):
            self.assertIn(needle, NATIVE_TEST)

    def test_build_runs_the_native_test(self):
        self.assertIn('usermap_base_test.cpp', read('ops', 'Build-Voice.ps1'))

    def test_hint_filter_is_wired(self):
        ncs = read('src', 'native', 'paris_usermap_ncs.cpp')
        for needle in ('0x1406D52B0ull', 'is_base_hint_list', 'paris_usermap_hint_filter', 'REGISTER_COMPONENT(paris_usermap_ncs::component)'):
            self.assertIn(needle, ncs)
        for needle in ('0x140A77D20ull', '0x140A76280ull', 'paris_usermap_map_wins', '[usermap map wins]', 'is_map_own_zone', 'is_data_table_type', '0x1406D43C0ull', 'ents_patched', '0x1405EAAD0ull', 'nav_pending'):
            self.assertIn(needle, ncs)
        self.assertNotIn('base_phase', read('ops', 'frame-cuts', 'frame-cut-edits.json'))
        self.assertIn("'paris_usermap_ncs.cpp'", read('ops', 'Build-Voice.ps1'))
        self.assertIn('src/native/paris_usermap_ncs.cpp', read('product.json'))
        self.assertIn('current_bases().push_back(zone.name);', HPP)


if __name__ == '__main__':
    unittest.main()
