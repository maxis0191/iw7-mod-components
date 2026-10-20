"""Reject untrusted getinfo evidence before it can enter the audit report."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "existing_client_audit", Path(__file__).resolve().parents[2] / "ops/Audit-ExistingClient.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class InfoEvidenceTest(unittest.TestCase):
    nonce = "a" * 32
    payload = ("\\challenge\\" + nonce + "\\clients\\0\\fs_game\\").encode("ascii")
    header = b"\xff\xff\xff\xffinfoResponse"

    def test_nonce_checked_empty_values_and_supported_separators(self):
        for separator in (b"\n", b" "):
            with self.subTest(separator=separator):
                fields = audit.parse_info(self.header + separator + self.payload + b"\n\0", self.nonce)
                self.assertEqual(fields["clients"], "0")
                self.assertEqual(fields["fs_game"], "")

    def test_refuses_forged_or_ambiguous_evidence(self):
        valid = self.header + b"\n" + self.payload
        cases = [
            valid.replace(self.nonce.encode(), b"b" * 32),
            valid + b"\\challenge\\" + self.nonce.encode(),
            valid + b"\\clients\\1", valid + b"\\unpaired",
            valid.replace(b"clients\\0", b"clients\\unknown"),
            self.header + b"Other\n" + self.payload,
            b"infoResponse\n" + self.payload,
            self.header + b"\n", valid.replace(b"fs_game", b"\xff"),
        ]
        for index, data in enumerate(cases):
            with self.subTest(index=index), self.assertRaises(ValueError):
                audit.parse_info(data, self.nonce)


if __name__ == "__main__":
    unittest.main()
