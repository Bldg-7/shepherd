#!/usr/bin/env python3
"""Session-only preparation gates: fake CLIs/transport/native UI seams only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
out = p.parse_args().output.resolve()
out.mkdir(parents=True, exist_ok=False)
for name in ('home', 'tmp', 'cache', 'node-fixture'):
    (out / name).mkdir(mode=0o700)
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
           HOME=str(out / 'home'), CFFIXED_USER_HOME=str(out / 'home'),
           TMPDIR=str(out / 'tmp'), CLANG_MODULE_CACHE_PATH=str(out / 'cache'))
sources = ['Shepherd/Agents/' + name + '.swift' for name in [
    'AgentRuntime', 'PiProcessIdentity', 'AgentHostExecutables', 'AgentSkillPreparation', 'AgentLaunchService', 'ExperimentalSettingsDiagnostics', 'AgentSavedSession',
    'AgentIdleStopPolicy', 'AgentLaunchState', 'AgentResumeConfirmation', 'AgentBrowserAdapter']]
sources += ['Shepherd/Hosts/Models/Machine.swift', 'Shepherd/Hosts/Models/AgentSkillSetup.swift',
            'Shepherd/Hosts/Views/AgentSkillSection.swift', 'Shepherd/Browser/BrowserKey.swift',
            'Shepherd/Browser/CDPPolicy.swift', 'Shepherd/HerdrKit/HerdrClient.swift',
            'Shepherd/HerdrKit/Transport/HerdrTransport.swift', 'Shepherd/HerdrKit/Terminal/ShellQuoting.swift']
sources += [str(x.relative_to(ROOT)) for x in sorted((ROOT / 'Shepherd/HerdrKit/Models').glob('*.swift'))]
sources += ['Tests/AgentBrowser/Phase3/AgentSkillPreparationSeams.swift', 'Tests/AgentBrowser/Phase3/AgentSkillServiceTests.swift']
identity = sources + ['Tests/AgentBrowser/Phase3/AgentSkillPreparationTests.swift', 'Tests/AgentBrowser/Phase3/RuntimeCoreTests.mjs']
identity += [str(x.relative_to(ROOT)) for x in (ROOT / 'Shepherd/Agents/AgentRuntime').glob('*.mjs')]
identity += ['Shepherd/Agents/AgentRuntime/skill/SKILL.md',
             'Shepherd/Agents/AgentRuntime/pi-guidance.md',
             'Shepherd/Agents/AgentRuntime/pi-entry.ts',
             'Tests/AgentBrowser/Phase3/PiIntegrationTests.mjs',
             'Tests/AgentBrowser/Phase3/PiMcpRegistrationTests.mjs',
             'Shepherd/HerdrKit/Terminal/LocalCommand.swift',
             'Tests/AgentBrowser/Phase3/AgentHostExecutablesTests.swift',
             'Tests/AgentBrowser/Phase3/ExperimentalSettingsDiagnosticsTests.swift']
(out / 'source-hashes.json').write_text(json.dumps({s: hashlib.sha256((ROOT / s).read_bytes()).hexdigest() for s in identity}, indent=2))
records = []
def stage(name, seconds, command):
    log = out / (name + '.log')
    code = subprocess.run([sys.executable, str(ROOT / 'Tests/AgentBrowser/Phase2/run-stage.py'),
                           '--timeout', str(seconds), '--natural-exit-grace', '10', '--log', str(log), '--', *command],
                          cwd=ROOT, env=env, timeout=seconds + 40).returncode
    record = json.loads(log.with_suffix('.stage.json').read_text())
    records.append(record)
    (out / 'stages.json').write_text(json.dumps(records, indent=2))
    if code or not record['naturalExitConfirmed'] or record['signalsSent'] or not record['cleanupVerified']:
        raise RuntimeError(name + ' failed; see retained log')

swift = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor', '-parse-as-library']
stage('node-runtime', 120, ['node', 'Tests/AgentBrowser/Phase3/RuntimeCoreTests.mjs'])
stage('pi-foundation', 60, ['node', '--test', 'Tests/AgentBrowser/Phase3/PiIntegrationTests.mjs'])
stage('pi-mcp-registration', 30, ['node', '--test', 'Tests/AgentBrowser/Phase3/PiMcpRegistrationTests.mjs'])
stage('executable-lookup-build', 60, [*swift, 'Shepherd/Agents/AgentRuntime.swift',
    'Shepherd/Agents/AgentHostExecutables.swift', 'Shepherd/HerdrKit/Terminal/LocalCommand.swift',
    'Tests/AgentBrowser/Phase3/AgentHostExecutablesTests.swift', '-o', str(out / 'executable-lookup-tests')])
stage('executable-lookup-tests', 30, [str(out / 'executable-lookup-tests'), str(out / 'node-fixture')])
stage('diagnostics-build', 60, [*swift, 'Shepherd/Agents/AgentRuntime.swift',
    'Shepherd/Agents/ExperimentalSettingsDiagnostics.swift',
    'Tests/AgentBrowser/Phase3/ExperimentalSettingsDiagnosticsTests.swift', '-o', str(out / 'diagnostics-tests')])
stage('diagnostics-tests', 20, [str(out / 'diagnostics-tests')])
stage('preparation-build', 60, [*swift, 'Shepherd/Agents/AgentSkillPreparation.swift',
                               'Tests/AgentBrowser/Phase3/AgentSkillPreparationTests.swift', '-o', str(out / 'preparation-tests')])
stage('preparation-tests', 20, [str(out / 'preparation-tests')])
stage('service-ui-build', 90, [*swift, *sources, '-o', str(out / 'service-tests')])
stage('service-tests', 30, [str(out / 'service-tests')])
stage('swift-runtime-build', 60, [*swift, 'Shepherd/Agents/AgentRuntime.swift',
                                 'Tests/AgentBrowser/Phase3/AgentRuntimeTests.swift', '-o', str(out / 'runtime-tests')])
stage('swift-runtime-tests', 20, [str(out / 'runtime-tests')])
(out / 'validation.json').write_text(json.dumps({'passed': True, 'stages': len(records),
    'syntheticOnly': True, 'actualCLIAuthentication': 'NOTRUN', 'actualGUI': 'NOTRUN',
    'actualCEF': 'NOTRUN', 'fullAppBuild': 'NOTRUN'}, indent=2))
