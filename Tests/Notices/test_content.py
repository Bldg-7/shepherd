#!/usr/bin/env python3
"""Offline content checks for the Stage 1 notice inventory; no build or network."""
import hashlib
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SEP = "========================================================================"


def section(text, title):
    marker = f"{SEP}\n{title}\n{SEP}\n"
    start = text.index(marker) + len(marker)
    end = text.find(f"\n\n{SEP}\n", start)
    return (text[start:] if end == -1 else text[start:end]).rstrip("\n")


def digest(path):
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


class NoticeContentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.inventory = json.loads((ROOT / "Tests/Notices/inventory.json").read_text())
        cls.mac = (ROOT / "Shepherd/ThirdPartyNotices.txt").read_text()
        cls.ios = (ROOT / "ShepherdMobile/ThirdPartyNotices.txt").read_text()

    def test_inventory_schema_and_pinned_fixtures(self):
        self.assertEqual(self.inventory["schema"], "shepherd.third-party-notices.inventory/v1")
        self.assertEqual(self.inventory["schemaStatus"], "frozen-for-package-and-gate-integration")
        for block in self.inventory["verbatimBlocks"]:
            self.assertEqual(digest(block["sourcePath"]), block["sha256"])

    def test_all_six_notice_blocks_are_verbatim(self):
        for block in self.inventory["verbatimBlocks"][:6]:
            title = block["sourcePath"]
            expected = "\n".join(line.rstrip(" \t") for line in (ROOT / title).read_text().splitlines()).rstrip("\n")
            self.assertEqual(section(self.mac, title), expected, title)

    def test_external_boringssl_license_is_complete_and_distinct(self):
        title = "build/SourcePackages/checkouts/swift-nio-ssl/Sources/CNIOBoringSSL (BoringSSL)"
        actual = section(self.mac, title)
        fixture = "\n".join(line.rstrip(" \t") for line in (ROOT / "Tests/Notices/fixtures/boringssl-817ab07-LICENSE.txt").read_text().splitlines()).rstrip("\n")
        self.assertTrue(actual.endswith(fixture))
        self.assertEqual(self.mac.count("CCryptoBoringSSL (BoringSSL)"), 1)
        self.assertEqual(self.mac.count("CNIOBoringSSL (BoringSSL)"), 1)

    def test_source_header_blocks_follow_the_frozen_extraction_rules(self):
        sha = (ROOT / "build/SourcePackages/checkouts/swift-nio/Sources/CNIOSHA1/c_nio_sha1.c").read_text().splitlines()[9:38]
        self.assertEqual(section(self.mac, "build/SourcePackages/checkouts/swift-nio/Sources/CNIOSHA1/c_nio_sha1.c:10-38 (FreeBSD SHA-1)"), "\n".join(line.rstrip(" \t") for line in sha))
        musl = (ROOT / "build/SourcePackages/checkouts/swift-certificates/Sources/X509/X509BaseTypes/TimeCalculations.swift").read_text().splitlines()[21:45]
        self.assertEqual(section(self.mac, "build/SourcePackages/checkouts/swift-certificates/Sources/X509/X509BaseTypes/TimeCalculations.swift:22-45 (musl)"), "\n".join(line.rstrip(" \t") for line in musl))
        self.assertEqual(self.mac.count("Vendor/Citadel/Sources/CCitadelBcrypt/bcrypt.c (ISC)"), 1)
        self.assertEqual(self.mac.count("Vendor/Citadel/Sources/CCitadelBcrypt/blf.c and blf.h (BSD advertising clause)"), 1)

    def test_ios_parity_blocks_are_byte_equal(self):
        title = "uSHET c09e0acafd86720efe42dc15c63e0cc228244c32 LICENSE (cpp_magic.h)"
        expected = "\n".join((ROOT / "Tests/Notices/fixtures/ushet-c09e0ac-LICENSE.txt").read_text().splitlines()[:22])
        self.assertEqual(section(self.mac, title), expected)
        self.assertEqual(section(self.ios, title), expected)
        line = "Copyright 2014-2020 The OpenSSL Project Authors. All Rights Reserved."
        self.assertEqual(self.mac.count(line), 1)
        self.assertEqual(self.ios.count(line), 1)

    def test_preserved_sections_and_negative_duplicate_controls(self):
        zstd = self.inventory["sectionInvariants"]["zstandardSection"]
        self.assertEqual(self.mac.count(zstd), 1)
        trademarks = f"{SEP}\nTrademarks\n{SEP}"
        self.assertEqual(self.mac.count(trademarks), 1)
        self.assertTrue(self.mac.rstrip().endswith("hrdrhrdrhrdr is not affiliated with or endorsed by them."))
        self.assertIn("Copyright (c) 1997 Niels Provos", self.mac)
        self.assertIn("Copyright (C) 1995, 1996, 1997, and 1998 WIDE Project.", self.mac)
        self.assertIn("Copyright © 2005-2020 Rich Felker, et al.", self.mac)

    def test_cef_metadata_is_not_a_committed_credits_copy(self):
        cef = self.inventory["cefCredits"]
        self.assertEqual(cef["bytes"], 8679939)
        self.assertEqual(cef["newlines"], 154598)
        self.assertEqual(digest(cef["sourcePath"]), cef["sha256"])
        self.assertFalse((ROOT / "ChromiumCredits.html").exists())


if __name__ == "__main__":
    unittest.main()
