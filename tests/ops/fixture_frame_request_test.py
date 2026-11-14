#!/usr/bin/env python3
"""The fixture's lab frame request (frame:<name>[:depth]): text test of src/native/paris_test_fixture.cpp and docs/UI-DUMP.md.
No game: the client reads the request file in the game, so what can be checked here is that the handler runs only the two console
commands a frame needs, validates the name like the other lab requests, is gated with them, and is documented."""
import os
import re
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')


def read(*p):
    with open(os.path.join(ROOT, *p), encoding='utf-8') as f:
        return f.read()


class FrameRequest(unittest.TestCase):
    src = read('src', 'native', 'paris_test_fixture.cpp')

    def body(self):
        m = re.search(r'bool frame_request\(const std::string& action\)\s*\{(.*?)\n        \}', self.src, re.S)
        self.assertTrue(m, 'frame_request is missing')
        return m.group(1)

    def test_runs_only_the_frame_commands(self):
        calls = re.findall(r'command::execute\(([^;]*?), true\)', self.body())
        self.assertEqual(calls, ['"paris_see_depth"', '"capture_frame iwz_" + name'])

    def test_name_is_validated_like_the_ui_requests(self):
        b = self.body()
        self.assertIn('name.size() > 24', b)
        self.assertIn('"abcdefghijklmnopqrstuvwxyz0123456789_"', b)
        self.assertIn('rest.substr(colon + 1) != "depth"', b)

    def test_gated_with_the_lab_key_requests(self):
        self.assertRegex(self.src, r'const bool key_input =[^;]*action\.rfind\("frame:", 0\) == 0;')
        self.assertIn('if (!frame_request(action)) return;', self.src)

    def test_logs_the_line_the_server_repository_reads(self):
        self.assertIn('[Paris frame request] %s depth=%d tick_ms=%llu', self.body())

    def test_documented(self):
        self.assertIn('`frame:<name>[:depth]`', read('docs', 'UI-DUMP.md'))


if __name__ == '__main__':
    unittest.main()