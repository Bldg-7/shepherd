#!/usr/bin/env python3
"""Opt-in smoke against a pinned, scratch-extracted macOS ARM64 hc archive.

No installer, PATH update, real agent, SSH, user core, or user config. Network is
blocked except the private core's Unix sockets. The caller downloads the archive
separately; its exact release checksum is verified before executing any bytes.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import socket
import subprocess
import sys
import time
import core_test_artifact as artifacts

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
artifacts.add_arguments(p)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()
assert platform.system() == "Darwin" and platform.machine() == "arm64", "pinned archive is macOS ARM64 only"
artifact = artifacts.select(a.archive, a.build_receipt)

def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as src:
        while block := src.read(1 << 20):
            value.update(block)
    return value.hexdigest()

out = a.output.resolve()
out.mkdir(mode=0o700, parents=True, exist_ok=False)
for name in ("home", "tmp", "cache", "bin", "core"):
    (out / name).mkdir(mode=0o700)
binary = out / "bin/herdr-core"
provenance = artifacts.extract(artifact, binary)
home = out / "core"
sock = home / "c.sock"
assert len(str(sock).encode()) < 104, "use a shorter /tmp output path"
core_env = {"PATH": "/usr/bin:/bin", "HOME": str(home), "XDG_STATE_HOME": str(home / "state"),
            "XDG_CONFIG_HOME": str(home / "config"), "XDG_RUNTIME_DIR": str(home / "runtime"),
            "HC_SESSION": "owned", "HC_SOCKET": str(sock), "LANG": "en_US.UTF-8", "DO_NOT_TRACK": "1"}
env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
       "DEVELOPER_DIR": os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"),
       "HOME": str(out / "home"), "CFFIXED_USER_HOME": str(out / "home"), "TMPDIR": str(out / "tmp"),
       "CLANG_MODULE_CACHE_PATH": str(out / "cache"), "LANG": "en_US.UTF-8"}
profile = out / "private-unix-only.sb"
profile.write_text('(version 1)\n(allow default)\n(deny network*)\n(allow network* (subpath ' + json.dumps(str(home)) + '))\n')
sandbox = ["/usr/bin/sandbox-exec", "-f", str(profile)]
# Verify denial against an owned ephemeral listener, never a user's service.
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0)); listener.listen(1)
    probe = "import errno,socket,sys\ns=socket.socket()\ntry: s.connect(('127.0.0.1',int(sys.argv[1])))\nexcept OSError as e: sys.exit(0 if e.errno in (errno.EPERM,errno.EACCES) else 2)\nsys.exit(1)\n"
    result = subprocess.run(sandbox + [sys.executable, "-I", "-c", probe, str(listener.getsockname()[1])],
                            env=core_env, capture_output=True, timeout=10)
    assert result.returncode == 0, "TCP denial canary failed"
sources = sorted(str(path.relative_to(ROOT)) for path in (ROOT / "ShepherdKit/Sources/ShepherdKit/CoreKit").glob("*.swift"))
test = "Tests/CoreProtocol/CoreRealProcessTests.swift"
(out / "source-hashes.json").write_text(json.dumps({name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                                                   for name in sources + [test, "Tests/CoreProtocol/core_test_artifact.py", str(Path(__file__).resolve().relative_to(ROOT))]}, indent=2))
(out / "provenance.json").write_text(json.dumps(provenance, indent=2))


def stage(name, seconds, args):
    log = out / (name + ".log")
    code = subprocess.run([sys.executable, str(ROOT / "Tests/AgentBrowser/Phase2/run-stage.py"),
                           "--timeout", str(seconds), "--natural-exit-grace", "10", "--log", str(log), "--", *args],
                          cwd=ROOT, env=env, timeout=seconds + 40).returncode
    receipt = json.loads(log.with_suffix(".stage.json").read_text())
    assert code == 0 and receipt["naturalExitConfirmed"] and not receipt["signalsSent"] and receipt["cleanupVerified"], name + ": " + str(log)


flags = ["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor", "-parse-as-library", "-warnings-as-errors"]
for feature in ("MemberImportVisibility", "NonisolatedNonsendingByDefault", "InferIsolatedConformances"):
    flags += ["-enable-upcoming-feature", feature]
exe = out / "real-core-tests"
stage("build", 120, flags + sources + [test, "-o", str(exe)])
report = out / "core-report.json"
try:
    stage("real-core", 60, sandbox + [str(exe), str(binary), str(home), str(report)])
finally:
    # Only this test's private socket/environment. Never `hc stop` on PATH and
    # never a signal to an unverified daemon PID or a whole process group.
    if sock.exists():
        stopped = subprocess.run(sandbox + [str(binary), "server", "stop"], env=core_env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        (out / "cleanup-status.json").write_text(json.dumps({"exitCode": stopped.returncode}))
    result = json.loads(report.read_text()) if report.exists() else {}
    pid = result.get("corePID")
    deadline = time.monotonic() + 5
    while True:
        alive = False
        if pid:
            try:
                os.kill(pid, 0)  # Liveness query only, never a terminating signal.
                alive = True
            except ProcessLookupError:
                pass
        if not alive and not sock.exists():
            break
        if time.monotonic() >= deadline:
            raise RuntimeError("owned core cleanup not confirmed; inspect retained artifacts")
        time.sleep(0.025)
assert result.get("passed") and result.get("stopAcknowledged") and result.get("connectChildrenReaped")
for name, expected in json.loads((out / "source-hashes.json").read_text()).items():
    assert digest(ROOT / name) == expected, "source changed during validation: " + name
(out / "validation.json").write_text(json.dumps({"passed": True, "realCore": "0.1.16", "artifactVariant": artifact["variant"],
    "officialRelease": artifact["officialRelease"], "ownCoreStopped": True,
    "ownSocketRemoved": True, "isolatedHomeAndSession": True, "externalNetworkDenied": True,
    "userCoreOrConfigTouched": False, "ssh": "NOTRUN", "attachAndSwiftTerm": "NOTRUN"}, indent=2))
print("PASS isolated real-core smoke; artifacts:", out)
