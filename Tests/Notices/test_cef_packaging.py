#!/usr/bin/env python3
"""Offline checks for staging Chromium credits and macOS resource wiring."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY_ROOT / "scripts" / "cef.sh"
PROJECT = REPOSITORY_ROOT / "shepherd.xcodeproj" / "project.pbxproj"
INVENTORY = REPOSITORY_ROOT / "Tests" / "Notices" / "inventory.json"


class CEFPackagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.inventory = json.loads(INVENTORY.read_text())
        cls.credits = cls.inventory["cefCredits"]
        cls.dist = REPOSITORY_ROOT / cls.credits["sourcePath"]
        if not cls.dist.is_file():
            raise unittest.SkipTest(f"private pinned CEF credits are unavailable: {cls.dist}")
        cls.test_root = Path(tempfile.mkdtemp(prefix="shphrd-87-cef-packaging-"))

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.test_root, ignore_errors=True)

    def make_cached_root(self, script: Path = SCRIPT, version: str | None = None) -> tuple[Path, Path]:
        root = self.test_root / f"root-{len(list(self.test_root.iterdir()))}"
        helper_sources = root / "CEFHelper"
        helper_sources.mkdir(parents=True)
        (helper_sources / "fingerprint-input").write_text("test-only fingerprint input\n")

        selected_version = version or self.credits["version"]
        name = f"cef_binary_{selected_version}_macosarm64_minimal"
        vendor = root / "Vendor" / "CEF"
        vendor.mkdir(parents=True)
        (vendor / name).symlink_to(self.dist.parent, target_is_directory=True)
        out = vendor / "out"
        out.mkdir()
        (out / ".built-from").write_text(self.fingerprint(script, helper_sources))
        return root, out

    @staticmethod
    def fingerprint(script: Path, helper_sources: Path) -> str:
        version = next(
            line.split("=", 1)[1].strip().strip("'")
            for line in script.read_text().splitlines()
            if line.startswith("CEF_VERSION=")
        )
        digest = hashlib.sha1()
        digest.update(f"{version}\n".encode())
        digest.update(script.read_bytes())
        for source in sorted(helper_sources.iterdir()):
            digest.update(source.read_bytes())
        return digest.hexdigest()

    @staticmethod
    def sha256(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()

    def run_cef(self, root: Path, script: Path = SCRIPT) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["CEF_ROOT"] = str(root)
        return subprocess.run(
            ["bash", str(script)],
            cwd=root,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def assert_staged_credits(self, staged: Path) -> None:
        self.assertTrue(staged.is_file())
        self.assertEqual(staged.stat().st_size, self.credits["bytes"])
        self.assertEqual(self.sha256(staged), self.credits["sha256"])

    def test_cold_stage_creates_pinned_resource(self) -> None:
        root, out = self.make_cached_root()
        result = self.run_cef(root)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Staging Chromium credits", result.stdout)
        self.assert_staged_credits(out / "ChromiumCredits.html")

    def test_warm_stage_keeps_valid_pinned_resource(self) -> None:
        root, out = self.make_cached_root()
        staged = out / "ChromiumCredits.html"
        shutil.copyfile(self.dist, staged)

        result = self.run_cef(root)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Staging Chromium credits", result.stdout)
        self.assertIn("is up to date", result.stdout)
        self.assert_staged_credits(staged)

    def test_missing_or_stale_stage_is_refreshed(self) -> None:
        for stale_contents in (None, "stale Chromium credits\n"):
            with self.subTest(stale_contents=stale_contents):
                root, out = self.make_cached_root()
                staged = out / "ChromiumCredits.html"
                if stale_contents is not None:
                    staged.write_text(stale_contents)

                result = self.run_cef(root)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Staging Chromium credits", result.stdout)
                self.assert_staged_credits(staged)

    def test_cef_version_selects_its_matching_distribution(self) -> None:
        version = "test-version"
        test_script = self.test_root / "cef-test-version.sh"
        test_script.write_text(
            SCRIPT.read_text().replace(
                f"CEF_VERSION='{self.credits['version']}'", f"CEF_VERSION='{version}'", 1
            )
        )
        test_script.chmod(0o755)
        root, out = self.make_cached_root(test_script, version)

        result = self.run_cef(root, test_script)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_staged_credits(out / "ChromiumCredits.html")

    def test_pinned_credits_constants_match_frozen_inventory(self) -> None:
        source = SCRIPT.read_text()
        self.assertIn(f"CEF_VERSION='{self.credits['version']}'", source)
        self.assertIn(f"CREDITS_BYTES={self.credits['bytes']}", source)
        self.assertIn(f"CREDITS_NEWLINES={self.credits['newlines']}", source)
        self.assertIn(f"CREDITS_SHA256='{self.credits['sha256']}'", source)
        self.assertIn("stage_credits", source)

    def test_project_wires_credits_as_a_macos_resource_before_embedding_cef(self) -> None:
        source = PROJECT.read_text()
        self.assertIn(
            "C0EF00000000000000000026 /* ChromiumCredits.html in Resources */ = "
            "{isa = PBXBuildFile; fileRef = C0EF00000000000000000016 /* ChromiumCredits.html */; "
            "platformFilters = (macos, ); };",
            source,
        )
        self.assertIn(
            "C0EF00000000000000000016 /* ChromiumCredits.html */ = "
            "{isa = PBXFileReference; lastKnownFileType = text.html; path = ChromiumCredits.html; "
            'sourceTree = "<group>"; };',
            source,
        )
        macos_resources = """000000000000000140000000 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			files = (
				A63E1D0D20AA408AA2C0C024 /* Shepherd/Agents/AgentRuntime in Resources */,
				C0EF00000000000000000026 /* ChromiumCredits.html in Resources */,"""
        self.assertIn(macos_resources, source)
        self.assertNotIn(
            "5A11000000000000000000B5 /* Resources */ = {\n"
            "\t\t\tisa = PBXResourcesBuildPhase;\n"
            "\t\t\tfiles = (\n"
            "\t\t\t\tC0EF00000000000000000026",
            source,
        )
        target_phases = source[source.index("000000000000000100000000 /* Shepherd */ = {"):]
        target_phases = target_phases[:target_phases.index("buildRules =")]
        self.assertLess(
            target_phases.index("000000000000000140000000 /* Resources */"),
            target_phases.index("C0EF00000000000000000002 /* Embed Browser Engine */"),
        )


if __name__ == "__main__":
    unittest.main()
