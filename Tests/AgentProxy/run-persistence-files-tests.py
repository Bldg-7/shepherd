#!/usr/bin/env python3
"""Compile and run only the conversation filesystem foundation offline.

This runner uses the checked-in Foundation/Darwin source and its owned synthetic
fixtures. It does not resolve packages, start the app/agent, access user state,
or make a network request. Every compile and test stage has natural-exit and
owned-descendant evidence from the existing bounded stage controller.
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
for name in ['home', 'tmp', 'cache', 'work']:
    (out / name).mkdir(mode=0o700)

env = dict(os.environ, HOME=str(out / 'home'), CFFIXED_USER_HOME=str(out / 'home'),
           TMPDIR=str(out / 'tmp'), CLANG_MODULE_CACHE_PATH=str(out / 'cache'))
source = ROOT / 'AgentProxy/Sources/AgentProxyForwarder/ConversationPersistenceFiles.swift'
tests = ROOT / 'Tests/AgentProxy/PersistenceFilesTests.swift'
stage_runner = ROOT / 'Tests/AgentBrowser/Phase2/run-stage.py'
identity = [source, tests, Path(__file__).resolve(), stage_runner]
assert all(path.is_file() for path in identity), 'missing filesystem-foundation input'
for path in [source, tests]:
    imports = [line.strip() for line in path.read_text().splitlines() if line.startswith('import ')]
    assert imports and set(imports) <= {'import Foundation', 'import Darwin'}, f'non-system import: {path}'

revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True, timeout=10).strip()
hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in identity}
manifest = {
    'gitRevision': revision,
    'inputs': hashes,
    'recipe': 'python3 Tests/AgentProxy/run-persistence-files-tests.py --output <new-0700-output>',
    'limits': {'indexBytes': 1 << 20, 'recordBytes': 32 << 20},
    'network': 'denied by sandbox-exec profile',
}
(out / 'frozen-inputs.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
profile = out / 'sandbox.sb'
profile.write_text('(version 1)\n(allow default)\n(deny network*)\n')
stages = []


def stage(name, command, seconds=30):
    log = out / (name + '.log')
    result = subprocess.run([
        sys.executable, str(stage_runner), '--timeout', str(seconds), '--natural-exit-grace', '10',
        '--log', str(log), '--', *command,
    ], cwd=ROOT, env=env, timeout=seconds + 40)
    record = json.loads(log.with_suffix('.stage.json').read_text())
    stages.append(record)
    (out / 'stages.json').write_text(json.dumps(stages, indent=2) + '\n')
    if result.returncode or not record['naturalExitConfirmed'] or record['signalsSent'] or not record['cleanupVerified']:
        raise RuntimeError(f'{name} failed; see {log}')


for mode, optimization in [('debug', '-Onone'), ('optimized', '-O')]:
    binary = out / mode / 'PersistenceFilesTests'
    binary.parent.mkdir(mode=0o700)
    work = out / 'work' / mode
    work.mkdir(mode=0o700)
    stage(mode + '-build', ['/usr/bin/sandbox-exec', '-f', str(profile), '/usr/bin/xcrun', 'swiftc',
                            '-swift-version', '5', optimization, '-module-cache-path', str(out / 'cache'),
                            '-o', str(binary), str(source), str(tests)])
    stage(mode + '-run', ['/usr/bin/sandbox-exec', '-f', str(profile), str(binary), str(work)])

print('PASS: Foundation/Darwin filesystem foundation Debug and optimized synthetic tests; network denied')
