#!/usr/bin/env python3
"""Artifact gate tests with inert bytes only: no executable is ever launched."""
from pathlib import Path
import copy
import hashlib
import io
import json
import tarfile
import tempfile
import unittest
import core_test_artifact as artifacts


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hc-artifact-test.")
        self.root = Path(self.temp.name)
        self.recipe = json.loads(artifacts.RECIPE.read_text())
        self.binary = b"inert-test-bytes-not-an-executable"
        self.archive = self.root / self.recipe["archiveName"]
        self.make_archive([(self.member("herdr-core", self.binary), self.binary)])
        self.receipt = {"schema": 1, "variant": self.recipe["id"], "officialRelease": False,
                        "recipeSHA256": artifacts.digest(artifacts.RECIPE),
                        "buildScriptSHA256": artifacts.digest(artifacts.HERE / "backport/build-backport.py"), "archive": self.archive.name,
                        "archiveSHA256": artifacts.digest(self.archive),
                        "binarySHA256": hashlib.sha256(self.binary).hexdigest(),
                        "toolchain": {"rustc": "rustc 1.95.0 (synthetic)", "zig": self.recipe["zigVersion"],
                                      "zigSHA256": self.recipe["zigBinarySHA256"]}, "checks": {}}
        for field in ("version", "coreCommit", "ghosttyCommit", "upstreamCommit", "patchSHA256", "patchedFormatterSHA256", "cargoLockSHA256"):
            self.receipt[field] = self.recipe[field]
        for stage in artifacts.CHECKS:
            log = self.root / (stage + ".log"); log.write_text("synthetic unit fixture, not build evidence\n")
            self.receipt["checks"][stage] = {"passed": True, "testCount": 1, "logSHA256": artifacts.digest(log)}
        self.path = self.root / "receipt.json"
        self.save()

    def tearDown(self):
        self.temp.cleanup()

    def save(self):
        self.path.write_text(json.dumps(self.receipt))

    @staticmethod
    def member(name, data):
        value = tarfile.TarInfo(name); value.size = len(data); value.mode = 0o755
        return value

    def make_archive(self, members):
        with tarfile.open(self.archive, "w:gz") as archive:
            for member, data in members: archive.addfile(member, io.BytesIO(data) if data is not None else None)

    def selected(self):
        return artifacts.select(build_receipt=self.path)

    def test_source_mode_is_explicit_and_not_official(self):
        value = self.selected()
        result = artifacts.extract(value, self.root / "core")
        self.assertFalse(result["officialRelease"])
        self.assertFalse(result["independentSignatureVerified"])
        self.assertEqual((self.root / "core").read_bytes(), self.binary)
        self.assertEqual((self.root / "core").stat().st_mode & 0o777, 0o700)

    def test_official_pin_is_not_weakened_by_source_mode(self):
        value = artifacts.select(archive=self.archive)
        with self.assertRaises(ValueError): artifacts.extract(value, self.root / "core")
        self.assertFalse((self.root / "core").exists())

    def test_exactly_one_mode(self):
        with self.assertRaises(ValueError): artifacts.select()
        with self.assertRaises(ValueError): artifacts.select(self.archive, self.path)

    def test_recipe_and_source_fields_are_pinned(self):
        original = copy.deepcopy(self.receipt)
        for field in ("variant", "version", "recipeSHA256", "buildScriptSHA256", "coreCommit", "ghosttyCommit", "upstreamCommit", "patchSHA256", "patchedFormatterSHA256", "cargoLockSHA256"):
            with self.subTest(field=field):
                self.receipt = copy.deepcopy(original); self.receipt[field] = "wrong"; self.save()
                with self.assertRaises(ValueError): self.selected()

    def test_cannot_label_backport_as_official(self):
        self.receipt["officialRelease"] = True; self.save()
        with self.assertRaises(ValueError): self.selected()

    def test_required_build_checks(self):
        original = copy.deepcopy(self.receipt)
        for stage in artifacts.CHECKS:
            self.receipt = copy.deepcopy(original); self.receipt["checks"][stage]["passed"] = False; self.save()
            with self.subTest(stage=stage), self.assertRaises(ValueError): self.selected()
        self.receipt = original; self.receipt["checks"].pop("core-build"); self.save()
        with self.assertRaises(ValueError): self.selected()

    def test_zero_test_count_is_not_coverage(self):
        self.receipt["checks"]["rust-core-unit-tests"]["testCount"] = 0; self.save()
        with self.assertRaises(ValueError): self.selected()

    def test_changed_or_missing_logs(self):
        log = self.root / "core-build.log"
        log.write_text("changed")
        with self.assertRaises(ValueError): self.selected()
        log.unlink()
        with self.assertRaises(OSError): self.selected()

    def test_toolchain_checks(self):
        original = copy.deepcopy(self.receipt)
        for field, value in [("rustc", "rustc 1.94.1"), ("zig", "0.17.0"), ("zigSHA256", "0" * 64)]:
            self.receipt = copy.deepcopy(original); self.receipt["toolchain"][field] = value; self.save()
            with self.subTest(field=field), self.assertRaises(ValueError): self.selected()

    def test_archive_path_cannot_escape(self):
        self.receipt["archive"] = "../other.tar.gz"; self.save()
        with self.assertRaises(ValueError): self.selected()

    def test_archive_symlink_rejected(self):
        real = self.root / "real.tar.gz"; self.archive.rename(real); self.archive.symlink_to(real)
        with self.assertRaises(ValueError): self.selected()

    def test_changed_archive_and_binary(self):
        value = self.selected(); self.archive.write_bytes(b"changed")
        with self.assertRaises(ValueError): artifacts.extract(value, self.root / "core")
        self.make_archive([(self.member("herdr-core", self.binary), self.binary)])
        self.receipt["archiveSHA256"] = artifacts.digest(self.archive)
        self.receipt["binarySHA256"] = "0" * 64; self.save()
        with self.assertRaises(ValueError): artifacts.extract(self.selected(), self.root / "core")
        self.assertFalse((self.root / "core").exists())

    def test_unsafe_members_never_extract(self):
        symlink = tarfile.TarInfo("herdr-core"); symlink.type = tarfile.SYMTYPE; symlink.linkname = "/etc/passwd"
        cases = [[(symlink, None)],
                 [(self.member("../escape", b"x"), b"x")],
                 [(self.member("herdr-core", b""), b"")],
                 [(self.member("herdr-core", b"a"), b"a"), (self.member("herdr-core", b"b"), b"b")],
                 [(self.member("LICENSE", b"x"), b"x")]]
        for index, members in enumerate(cases):
            self.make_archive(members)
            value = {"archive": self.archive, "archiveSHA256": artifacts.digest(self.archive)}
            with self.subTest(index=index), self.assertRaises(ValueError): artifacts.extract(value, self.root / "core")
            self.assertFalse((self.root / "core").exists())

    def test_existing_destination_is_not_overwritten_or_deleted(self):
        (self.root / "core").write_bytes(b"keep")
        with self.assertRaises(FileExistsError): artifacts.extract(self.selected(), self.root / "core")
        self.assertEqual((self.root / "core").read_bytes(), b"keep")


if __name__ == "__main__":
    unittest.main()
