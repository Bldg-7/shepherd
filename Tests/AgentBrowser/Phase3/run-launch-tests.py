#!/usr/bin/env python3
"""Finite launch/UI-service gates, retaining source hashes and failure history."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
RUNNER = ROOT / 'Tests/AgentBrowser/Phase2/run-stage.py'


def manifest():
    names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT, timeout=10).decode().split('\0')
    return {name: {'sha256': hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), 'mode': oct((ROOT / name).stat().st_mode & 0o777)}
            for name in sorted(set(names) - {''}) if (ROOT / name).is_file() and not (ROOT / name).is_symlink()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--stage', choices=['api', 'transport', 'herdr', 'resume-safety', 'debug', 'release', 'ios'], action='append', required=True)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--agent-kind', choices=['claude', 'codex'], help='Test-only isolated agent case; default runs both')
    args = parser.parse_args()
    if args.agent_kind and any(stage not in ['herdr', 'resume-safety'] for stage in args.stage):
        parser.error('--agent-kind requires only herdr/resume-safety stages')
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    records = []
    os.environ['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'

    def stage(name, seconds, command):
        before = manifest()
        attempt = 1
        log = out / (name + '-1.log')
        while log.exists():
            attempt += 1
            log = out / (name + '-' + str(attempt) + '.log')
        log.with_suffix('.source.json').write_text(json.dumps(before, indent=2, sort_keys=True))
        log.with_suffix('.command.json').write_text(json.dumps({'argv': command, 'cwd': str(ROOT), 'developerDir': os.environ['DEVELOPER_DIR'], 'agentKinds': [args.agent_kind] if args.agent_kind else ['claude', 'codex']}, indent=2))
        code = subprocess.run([sys.executable, str(RUNNER), '--timeout', str(seconds), '--natural-exit-grace', '30', '--log', str(log), '--', *command], cwd=ROOT, timeout=seconds + 30).returncode
        record = json.loads(log.with_suffix('.stage.json').read_text())
        passed = code == 0 and record.get('naturalExitConfirmed') and not record.get('signalsSent') and record.get('cleanupVerified') and before == manifest()
        records.append({'stage': name, 'passed': bool(passed), 'record': str(log.with_suffix('.stage.json')), 'sourceManifest': str(log.with_suffix('.source.json'))})
        if not passed:
            raise RuntimeError(name + ' failed; retained exact log and record')

    try:
        for selected in args.stage:
            if selected == 'api':
                sources = ['Shepherd/Agents/AgentRuntime.swift', 'Shepherd/Agents/AgentSavedSession.swift', 'Shepherd/Agents/AgentIdleStopPolicy.swift', 'Shepherd/Agents/AgentLaunchState.swift', 'Shepherd/HerdrKit/HerdrClient.swift', 'Shepherd/HerdrKit/Transport/HerdrTransport.swift', 'Shepherd/HerdrKit/Terminal/ShellQuoting.swift'] + [str(p.relative_to(ROOT)) for p in sorted((ROOT / 'Shepherd/HerdrKit/Models').glob('*.swift'))]
                stage('api-build', 60, ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', *sources, 'Tests/AgentBrowser/Phase3/AgentLaunchAPITests.swift', '-o', str(out / 'AgentLaunchAPITests')])
                stage('api-state', 20, [str(out / 'AgentLaunchAPITests')])
            elif selected == 'transport':
                stage('local-command-build', 60, ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', 'Shepherd/HerdrKit/Terminal/LocalCommand.swift', 'Tests/AgentBrowser/Phase3/LocalCommandTests.swift', '-o', str(out / 'LocalCommandTests')])
                stage('local-command', 45, [str(out / 'LocalCommandTests')])
            elif selected in ['herdr', 'resume-safety']:
                if args.app is None: parser.error('--app required for actual integrated service fixture')
                name = 'herdr-launch-lifecycle' if selected == 'herdr' else 'idle-stop-safety'
                if args.agent_kind: name += '-' + args.agent_kind
                stage(name, 250, ['node', 'Tests/AgentBrowser/Phase3/HerdrLaunchLifecycleTests.mjs', str(args.app.resolve()), str(out / (name + '-' + str(os.getpid())))] + (['--verify-idle-stop'] if selected == 'resume-safety' else []) + (['--agent-kind', args.agent_kind] if args.agent_kind else []))
            else:
                config = 'Release' if selected == 'release' else 'Debug'
                destination = {'debug': 'platform=macOS,arch=arm64', 'release': 'generic/platform=macOS', 'ios': 'generic/platform=iOS Simulator'}[selected]
                command = ['xcodebuild', '-project', 'shepherd.xcodeproj', '-scheme', 'Shepherd', '-configuration', config, '-destination', destination, '-derivedDataPath', str(out / (selected + '-DerivedData'))]
                command += ['CODE_SIGNING_ALLOWED=NO'] if selected == 'ios' else ['CODE_SIGN_IDENTITY=-', 'CODE_SIGNING_REQUIRED=NO']
                command += ['ARCHS=arm64 x86_64', 'ONLY_ACTIVE_ARCH=NO'] if selected == 'release' else []
                command += ['PRODUCT_BUNDLE_IDENTIFIER=com.bldg-7.shepherd.phase3-ui-test'] if selected == 'debug' else []
                stage(selected + '-build', 600, command)
    finally:
        (out / ('validation-' + str(os.getpid()) + '.json')).write_text(json.dumps({'stages': records, 'allPassed': bool(records) and all(r['passed'] for r in records), 'actualUIAutomation': False, 'agentKinds': [args.agent_kind] if args.agent_kind else ['claude', 'codex'], 'isolatedAgentCase': args.agent_kind is not None}, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
