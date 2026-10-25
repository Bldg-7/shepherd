#!/usr/bin/env python3
"""Executable, controlled-timing harness for the iOS Board-cache coordinator.

It compiles the production MobileAgentListCache, MobileBoardLoadCoordinator,
AgentListCache and MachineStore. A private harness ShepherdKit module supplies
only controllable monitor/model publication values and an in-memory credential
store; disk cache and retirement journal use owned temporary files.
"""
from pathlib import Path
import argparse, hashlib, json, os, platform, subprocess

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, mode=0o700, exist_ok=False)
for name in ("home", "tmp", "cache", "module", "work"):
    (out / name).mkdir(mode=0o700)
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer", HOME=str(out / "home"),
           CFFIXED_USER_HOME=str(out / "home"), TMPDIR=str(out / "tmp"), CLANG_MODULE_CACHE_PATH=str(out / "cache"))
kit_sources = [
    "ShepherdKit/Sources/ShepherdKit/Resources.swift",
    "ShepherdKit/Sources/ShepherdKit/Machines/Machine.swift",
    "ShepherdKit/Sources/ShepherdKit/Machines/AgentListCache.swift",
    "ShepherdKit/Sources/ShepherdKit/Machines/MachineStore.swift",
    "Tests/Mobile/CoordinatorHarnessShepherdKit.swift",
]
harness_sources = [
    "ShepherdMobile/MobileAgentListCache.swift",
    "ShepherdMobile/MobileBoardLoadCoordinator.swift",
    "Tests/Mobile/MobileAgentListCacheCoordinatorHarness.swift",
]
all_sources = kit_sources + harness_sources
(out / "source-hashes.json").write_text(json.dumps({p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in all_sources}, indent=2))
target = platform.machine() + "-apple-macos26.6.2"
kit_command = ["xcrun", "swiftc", "-target", target, "-swift-version", "6", "-default-isolation", "MainActor",
               "-parse-as-library", "-emit-library", "-emit-module", "-module-name", "ShepherdKit",
               "-emit-module-path", str(out / "module" / "ShepherdKit.swiftmodule"), *kit_sources,
               "-o", str(out / "module" / "libShepherdKit.dylib")]
result = subprocess.run(kit_command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
(out / "kit-build.log").write_text(result.stdout + result.stderr)
if result.returncode:
    raise SystemExit(result.returncode)
harness_command = ["xcrun", "swiftc", "-target", target, "-swift-version", "6", "-default-isolation", "MainActor",
                   "-parse-as-library", "-I", str(out / "module"), "-L", str(out / "module"), "-lShepherdKit",
                   "-Xlinker", "-rpath", "-Xlinker", str(out / "module"), *harness_sources,
                   "-o", str(out / "mobile-agent-list-cache-coordinator-harness")]
result = subprocess.run(harness_command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
(out / "harness-build.log").write_text(result.stdout + result.stderr)
if result.returncode:
    raise SystemExit(result.returncode)
result = subprocess.run([str(out / "mobile-agent-list-cache-coordinator-harness"), str(out / "work")], cwd=ROOT, env=env,
                        capture_output=True, text=True, timeout=45)
(out / "harness.log").write_text(result.stdout + result.stderr)
if result.returncode:
    raise SystemExit(result.returncode)
(out / "validation.json").write_text(json.dumps({
    "passed": True,
    "actualProduction": ["MobileAgentListCache", "MobileBoardLoadCoordinator", "AgentListCache", "MachineStore", "RetiredCacheIdentities"],
    "fakes": ["MachineMonitor publication values", "MachineMonitors registry", "Agent/Tab/Workspace model values", "in-memory MachineSecretStore"],
    "ownedPersistence": str(out / "work"),
    "networkAccess": False, "ssh": False, "keychain": False, "userDefaults": "isolated per-run suite only", "device": False,
}, indent=2))
print(result.stdout, end="")
