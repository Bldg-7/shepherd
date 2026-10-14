#!/usr/bin/env python3
"""The actual browser listener over swift-nio on owned ephemeral loopback ports.
No app, CEF, herdr or user port is involved; the one child spawned is /bin/sleep."""
import argparse, hashlib, json, os, shutil, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
p.add_argument('--dependencies', type=Path, required=True,
               help='folder holding swift-nio and its swift-atomics/collections/system siblings')
a = p.parse_args(); out = a.output.resolve(); out.mkdir(parents=True, exist_ok=False)
for name in ['home', 'tmp', 'cache', 'package/Sources/Listener']: (out / name).mkdir(parents=True, mode=0o700)
env = dict(os.environ, HOME=str(out / 'home'), CFFIXED_USER_HOME=str(out / 'home'), TMPDIR=str(out / 'tmp'),
           CLANG_MODULE_CACHE_PATH=str(out / 'cache'), DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
           SWIFTCI_USE_LOCAL_DEPS='1')
sources = ['Shepherd/Browser/CDPListener.swift', 'Shepherd/Browser/CDPPolicy.swift',
           'Shepherd/CredentialBroker/CredentialBrokerContracts.swift', 'Shepherd/CredentialBroker/CredentialBroker.swift',
           'Shepherd/CredentialBroker/Interface/CredentialCLIService.swift', 'Shepherd/PasswordManagers/PasswordManagerProviderID.swift',
           'Shepherd/PasswordManagers/PasswordManagerProvider.swift', 'Tests/AgentBrowser/Phase3/CDPListenerTests.swift']
hashes = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sources}
(out / 'source-hashes.json').write_text(json.dumps(hashes, indent=2))
for name in sources: shutil.copy2(ROOT / name, out / 'package/Sources/Listener' / Path(name).name)
# The app target's Swift 5 mode, default isolation and upcoming features.
features = ['DisableOutwardActorInference', 'GlobalActorIsolatedTypesUsability', 'InferIsolatedConformances',
            'InferSendableFromCaptures', 'MemberImportVisibility', 'NonisolatedNonsendingByDefault']
flags = ['-default-isolation', 'MainActor'] + [x for f in features for x in ('-enable-upcoming-feature', f)]
package = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Listener", platforms: [.macOS("26.0")], dependencies: [
    .package(path: "%s")
], targets: [.executableTarget(name: "Listener", dependencies: [
    .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"),
    .product(name: "NIOHTTP1", package: "swift-nio"), .product(name: "NIOWebSocket", package: "swift-nio")
], swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(%s)])])
''' % (a.dependencies.resolve() / 'swift-nio', json.dumps(flags))
(out / 'package/Package.swift').write_text(package)
records = []
def stage(name, seconds, command):
    log = out / (name + '.log')
    code = subprocess.run([sys.executable, str(ROOT / 'Tests/AgentBrowser/Phase2/run-stage.py'), '--timeout', str(seconds),
                           '--natural-exit-grace', '15', '--log', str(log), '--', *command], cwd=ROOT, env=env, timeout=seconds + 50).returncode
    record = json.loads(log.with_suffix('.stage.json').read_text()); records.append(record)
    (out / 'stages.json').write_text(json.dumps(records, indent=2))
    if code or not record['naturalExitConfirmed'] or record['signalsSent'] or not record['cleanupVerified']:
        raise RuntimeError(name + ' failed; see retained log')
stage('listener-build', 420, ['/usr/bin/xcrun', 'swift', 'build', '--package-path', str(out / 'package'), '--jobs', '4', '--disable-automatic-resolution'])
stage('listener-tests', 30, [str(out / 'package/.build/debug/Listener')])
assert hashes == {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sources}, 'source changed during validation'
(out / 'validation.json').write_text(json.dumps({'passed': True, 'stages': len(records), 'actualNIOListener': True,
    'ephemeralLoopbackPortsOnly': True, 'actualApp': 'NOTRUN', 'actualCEF': 'NOTRUN'}, indent=2))
