#!/usr/bin/env python3
"""Compile the conversation core (Foundation and system CryptoKit) offline.

No app, agent, provider request, launchd registration or user settings are used.
Each compiler/test command is bounded by the existing natural-exit test runner.
This stage covers capture bounds, SSE framing, request-history projection and
Anthropic/Responses assembly and bounded in-memory snapshot storage, not
provider classification, compression, recorder integration, the read socket or iOS UI.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False, mode=0o700)
for name in ['home', 'tmp', 'cache']:
    (out / name).mkdir(mode=0o700)
env = dict(os.environ, HOME=str(out / 'home'), CFFIXED_USER_HOME=str(out / 'home'),
           TMPDIR=str(out / 'tmp'), CLANG_MODULE_CACHE_PATH=str(out / 'cache'))
sources = sorted((ROOT / 'AgentProxy/Sources/AgentProxyCore').glob('*.swift'))
assert sources, 'no core sources'
tests = sorted((ROOT / 'Tests/AgentProxy/Core').glob('*.swift'))
assert tests, 'no core tests'
identity = sources + tests + [ROOT / 'AgentProxy/Package.swift', Path(__file__).resolve()]
(out / 'source-hashes.json').write_text(json.dumps({str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                                 for p in identity}, indent=2))
profile = out / 'sandbox.sb'
profile.write_text('(version 1)\n(allow default)\n(deny network*)\n')
stages = []


def stage(name, command, seconds=120):
    log = out / (name + '.log')
    result = subprocess.run([
        sys.executable, str(ROOT / 'Tests/AgentBrowser/Phase2/run-stage.py'),
        '--timeout', str(seconds), '--natural-exit-grace', '10', '--log', str(log), '--', *command,
    ], cwd=ROOT, env=env, timeout=seconds + 40)
    record = json.loads(log.with_suffix('.stage.json').read_text())
    stages.append(record)
    (out / 'stages.json').write_text(json.dumps(stages, indent=2))
    if result.returncode or not record['naturalExitConfirmed'] or record['signalsSent'] or not record['cleanupVerified']:
        raise RuntimeError(f'{name} failed; see {log}')


# Read the manifest, without resolving dependencies or changing Package.resolved.
dump = subprocess.run([
    '/usr/bin/xcrun', 'swift', 'package', '--package-path', str(ROOT / 'AgentProxy'),
    '--scratch-path', str(out / 'manifest-scratch'), 'dump-package',
], cwd=ROOT, env=env, capture_output=True, timeout=120)
(out / 'manifest.log').write_bytes(dump.stderr)
assert dump.returncode == 0, 'manifest could not be read'
manifest = json.loads(dump.stdout)
core = next(t for t in manifest['targets'] if t['name'] == 'AgentProxyCore')
assert core['type'] == 'regular' and core['dependencies'] == [], 'capture core must be standalone'
assert any(p['name'] == 'AgentProxyCore' and p['targets'] == ['AgentProxyCore'] for p in manifest['products'])
assert manifest.get('swiftLanguageVersions') == ['5']

for mode, optimization in [('debug', '-Onone'), ('release', '-O')]:
    build = out / mode
    build.mkdir()
    module = build / 'AgentProxyCore.swiftmodule'
    library = build / 'libAgentProxyCore.dylib'
    common = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', optimization, '-parse-as-library',
              '-module-cache-path', str(out / 'cache')]
    stage(mode + '-core-build', common + ['-emit-module', '-emit-library', '-module-name', 'AgentProxyCore',
                                        '-emit-module-path', str(module), '-o', str(library), *map(str, sources)])
    binary = build / 'CaptureTests'
    stage(mode + '-test-build', common + ['-I', str(build), '-L', str(build), '-lAgentProxyCore',
                                        '-Xlinker', '-rpath', '-Xlinker', str(build), '-o', str(binary), *map(str, tests)])
    stage(mode + '-capture-tests', ['/usr/bin/sandbox-exec', '-f', str(profile), str(binary)], seconds=30)
    print((out / (mode + '-capture-tests.log')).read_text().strip())
sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'],
                              cwd=ROOT, env=env, text=True, timeout=30).strip()
stage('ios-core-typecheck', ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                             '-typecheck', '-module-name', 'AgentProxyCore', '-sdk', sdk,
                             '-target', 'arm64-apple-ios17.0-simulator', '-module-cache-path', str(out / 'cache'),
                             *map(str, sources)])
print('PASS: capture core manifest, Debug and optimized tests, iOS typecheck; no network or app launch')
