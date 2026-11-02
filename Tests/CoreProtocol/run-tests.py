#!/usr/bin/env python3
"""hc wire/RPC tests and an owned local pipe peer. No installed core, app, SSH,
accounts or network.

Produces independent Python struct.pack vectors and cross-checks Swift output.
Compile in the package's Swift 6 isolation mode and typecheck production sources
for iOS Simulator. Every stage has a deadline and isolated HOME.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
out = parser.parse_args().output.resolve()
out.mkdir(mode=0o700, parents=True, exist_ok=False)
for name in ("home", "tmp", "cache"):
    (out / name).mkdir(mode=0o700)
env = {
    "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
    "DEVELOPER_DIR": os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"),
    "HOME": str(out / "home"),
    "CFFIXED_USER_HOME": str(out / "home"),
    "TMPDIR": str(out / "tmp"),
    "CLANG_MODULE_CACHE_PATH": str(out / "cache"),
    "LANG": "en_US.UTF-8",
}
sources = ["ShepherdKit/Sources/ShepherdKit/CoreKit/" + name for name in
           ("CoreEventLines.swift", "CoreHandshake.swift", "CoreWire.swift", "CoreRPC.swift",
            "CoreByteTransport.swift", "CoreProcessTransport.swift", "CoreRPCConnection.swift")]
tests = "Tests/CoreProtocol/CoreProtocolTests.swift"
rpc_tests = "Tests/CoreProtocol/CoreRPCTests.swift"
connection_tests = "Tests/CoreProtocol/CoreConnectionTests.swift"
peer = "Tests/CoreProtocol/fixture-core.py"
# First-party language modes must not silently drift back to Swift 5. Vendor
# packages own their modes and are intentionally not rewritten by this project.
import re
for package in ("ShepherdKit", "AgentProxy"):
    manifest = (ROOT / package / "Package.swift").read_text()
    assert re.search(r"swiftLanguageModes:\s*\[\.v6\]", manifest), package
modes = re.findall(r"SWIFT_VERSION\s*=\s*([^;]+);", (ROOT / "shepherd.xcodeproj/project.pbxproj").read_text())
assert modes and set(modes) == {"6.0"}, modes
(out / "source-hashes.json").write_text(json.dumps({
    name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
    for name in sources + [tests, rpc_tests, connection_tests, peer, str(Path(__file__).resolve().relative_to(ROOT))]
}, indent=2))
(out / "compiler.txt").write_text(subprocess.check_output(["xcrun", "swiftc", "--version"], env=env, text=True, timeout=30))

# Protocol constants are intentionally not imported from the Swift implementation.
rows = [
    (0, 0, b'{"jsonrpc":"2.0","id":9,"result":{}}'),
    (0x12345678, 0, b"\x00\xff\x1b[31m\xe9\x9f\x93\n"),
    (1, 0, b""),
    (0x01020304, 1, struct.pack("<I", 262144)),
    (0xffffffff, 1, struct.pack("<I", 0xffffffff)),
    (7, 2, b""),
    (8, 2, b'{"reason":"exited","exit_code":0,"signal":null}'),
    (9, 3, struct.pack("<HH", 120, 40)),
    (10, 3, struct.pack("<HH", 65535, 65535)),
    (11, 4, b"\x00"),
    (12, 4, b"\x01"),
    (13, 5, b'{"fg":[255,255,255],"bg":[0,0,0],"cell":[8,16]}'),
]
vectors = [{"channel": ch, "kind": kind, "payloadHex": payload.hex(),
            "wireHex": (struct.pack("<IBI", ch, kind, len(payload)) + payload).hex()}
           for ch, kind, payload in rows]
fixture = out / "wire-vectors.json"
fixture.write_text(json.dumps(vectors, indent=2))
stages = []


def stage(name, seconds, args):
    log = out / (name + ".log")
    code = subprocess.run([
        sys.executable, str(ROOT / "Tests/AgentBrowser/Phase2/run-stage.py"),
        "--timeout", str(seconds), "--natural-exit-grace", "10", "--log", str(log), "--", *args,
    ], cwd=ROOT, env=env, timeout=seconds + 40).returncode
    result = json.loads(log.with_suffix(".stage.json").read_text())
    assert code == 0 and result["naturalExitConfirmed"] and not result["signalsSent"] and result["cleanupVerified"], f"{name}: {log}"
    stages.append(name)


upcoming = ["MemberImportVisibility", "NonisolatedNonsendingByDefault", "InferIsolatedConformances"]
flags = ["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor", "-parse-as-library", "-warnings-as-errors"]
for feature in upcoming:
    flags += ["-enable-upcoming-feature", feature]
binary = out / "wire-tests-swift6"
stage("build-swift6", 120, flags + sources + [tests, "-o", str(binary)])
encoded = out / "swift-encoded-6.json"
stage("test-swift6", 60, [str(binary), str(fixture), str(encoded)])
actual = json.loads(encoded.read_text())
assert actual == [v["wireHex"] for v in vectors]
for raw, expected in zip(actual, rows):
    wire = bytes.fromhex(raw)
    ch, kind, length = struct.unpack("<IBI", wire[:9])
    assert (ch, kind, wire[9:]) == expected and length == len(wire[9:])

rpc_binary = out / "rpc-tests-swift6"
stage("rpc-build", 120, flags + sources + [rpc_tests, "-o", str(rpc_binary)])
rpc_wire = out / "rpc-exact-integers.bin"
stage("rpc-tests", 60, [str(rpc_binary), str(rpc_wire)])
wire = rpc_wire.read_bytes()
ch, kind, length = struct.unpack("<IBI", wire[:9])
assert (ch, kind, length) == (0, 0, len(wire) - 9)
request = json.loads(wire[9:])
assert request == {"jsonrpc": "2.0", "id": (1 << 64) - 1, "method": "doc.set", "params": {"version": (1 << 64) - 1}}

connection_binary = out / "connection-tests-swift6"
stage("connection-build", 120, flags + sources + [connection_tests, "-o", str(connection_binary)])
profile = out / "no-network.sb"
profile.write_text("(version 1)\n(allow default)\n(deny network*)\n")
env["CORE_UNEXPECTED_PARENT_ENV"] = "must-not-reach-child"
stage("connection-tests", 60, ["/usr/bin/sandbox-exec", "-f", str(profile), str(connection_binary),
                               sys.executable, str(ROOT / peer), str(out / "owned child home")])

sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], env=env, text=True, timeout=30).strip()
stage("ios-typecheck", 120, flags + ["-typecheck", "-sdk", sdk,
                                   "-target", platform.machine() + "-apple-ios17.0-simulator", *sources])
for name, digest in json.loads((out / "source-hashes.json").read_text()).items():
    assert hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest, "source changed during validation: " + name
(out / "validation.json").write_text(json.dumps({
    "passed": True, "stages": stages, "independentPythonVectors": len(vectors),
    "realCore": False, "ownedStdioPeer": True, "ssh": False, "network": False, "app": False,
    "swiftTermInterop": "NOTRUN", "coreVersionInterop": "NOTRUN",
}, indent=2))
print(f"PASS CoreProtocol: {len(stages)} stages; artifacts: {out}")
