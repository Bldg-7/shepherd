#!/usr/bin/env python3
"""Synthetic, owned-storage checks for the mobile Board cache DTO and disk store."""
from pathlib import Path
import argparse, hashlib, json, os, platform, subprocess, sys

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(mode=0o700, parents=True, exist_ok=False)
for name in ["home", "tmp", "cache", "work"]:
    (out / name).mkdir(mode=0o700)
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer", HOME=str(out / "home"),
           CFFIXED_USER_HOME=str(out / "home"), TMPDIR=str(out / "tmp"), CLANG_MODULE_CACHE_PATH=str(out / "cache"))
sources = [
    "ShepherdKit/Sources/ShepherdKit/Resources.swift",
    "ShepherdKit/Sources/ShepherdKit/Machines/Machine.swift",
    "ShepherdKit/Sources/ShepherdKit/Machines/AgentListCache.swift",
    "Tests/Machines/AgentListCacheTests.swift",
]
(out / "source-hashes.json").write_text(json.dumps({name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sources}, indent=2))
command = ["xcrun", "swiftc", "-target", platform.machine() + "-apple-macos26.6.2", "-swift-version", "6",
           "-default-isolation", "MainActor", "-parse-as-library", *sources, "-o", str(out / "agent-list-cache-tests")]
result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
(out / "build.log").write_text(result.stdout + result.stderr)
if result.returncode:
    raise SystemExit(result.returncode)
result = subprocess.run([str(out / "agent-list-cache-tests"), str(out / "work")], cwd=ROOT, env=env,
                        capture_output=True, text=True, timeout=30)
(out / "test.log").write_text(result.stdout + result.stderr)
if result.returncode:
    raise SystemExit(result.returncode)
(out / "validation.json").write_text(json.dumps({
    "passed": True,
    "networkAccess": False,
    "realKeychainAccess": False,
    "realHerdr": False,
    "ownedTemporaryStorage": True,
    "checks": "restart, allowlist, empty/failure retention, identity invalidation, bounds, corruption, atomic failure",
}, indent=2))
print(result.stdout, end="")
