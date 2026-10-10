#!/usr/bin/env python3
"""Focused opt-in policy and owned Debug app/service gates (not UI automation)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
STAGE = ROOT / 'Tests/AgentBrowser/Phase2/run-stage.py'


def manifest():
    names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT, timeout=10).decode().split('\0')
    return {name: {'sha256': hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), 'mode': oct((ROOT / name).stat().st_mode & 0o777)}
            for name in sorted(set(names) - {''}) if (ROOT / name).is_file() and not (ROOT / name).is_symlink()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--app-executable', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    app = args.app_executable.resolve()
    if not app.is_file() or not os.access(app, os.X_OK):
        parser.error('--app-executable must be a full executable path, not an app directory')
    source = manifest()
    (output / 'source.json').write_text(json.dumps(source, indent=2, sort_keys=True))
    records = []

    def stage(name, seconds, command, environment=None):
        log = output / (name + '.log')
        if log.exists():
            raise RuntimeError('Use a fresh output directory; evidence is never overwritten')
        argv = [sys.executable, str(STAGE), '--timeout', str(seconds), '--natural-exit-grace', '15', '--log', str(log)]
        for key, value in (environment or {}).items():
            argv += ['--env', key + '=' + value]
        argv += ['--', *command]
        code = subprocess.run(argv, cwd=ROOT, timeout=seconds + 45).returncode
        record = json.loads(log.with_suffix('.stage.json').read_text())
        records.append(record)
        if code or not record['naturalExitConfirmed'] or record['signalsSent'] or not record['cleanupVerified']:
            raise RuntimeError(name + ' failed; forced cleanup is not a healthy pass')

    try:
        binary = output / 'ShepherdBrowserFeatureTests'
        stage('policy-build', 60, ['/usr/bin/xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', 'Shepherd/Browser/ShepherdBrowserFeature.swift', 'Shepherd/PasswordManagers/PasswordManagerProviderID.swift', 'Shepherd/PasswordManagers/PasswordManagerPreferences.swift', 'Shepherd/PasswordManagers/PasswordManagerProvider.swift', 'Shepherd/PasswordManagers/PasswordManagerCommandExecutor.swift', 'Shepherd/PasswordManagers/BitwardenUnlockCommand.swift', 'Shepherd/PasswordManagers/CLICredentialProvider.swift', 'Shepherd/PasswordManagers/PasswordManagerConnectionCoordinator.swift', 'Shepherd/HerdrKit/Terminal/LocalCommand.swift', 'Tests/AgentBrowser/Phase3/ShepherdBrowserFeatureTests.swift', '-o', str(binary)])
        stage('policy-tests', 20, [str(binary)])
        with tempfile.TemporaryDirectory(prefix='shepherd-feature-owned-', dir='/tmp') as temporary:
            owned = Path(temporary)
            os.chmod(owned, 0o700)
            home = owned / 'home'; home.mkdir()
            browser = owned / 'browser'; browser.mkdir()
            profile = browser / 'preserved-profile'; profile.mkdir()
            (profile / 'cookie-sentinel').write_text('cookie-preserved')
            (browser / 'source-sentinel').write_text('source-preserved')
            (browser / 'browsers.json').write_text(json.dumps({'browsers': [], 'foldersToDelete': ['preserved-profile']}))
            result = owned / 'result.json'
            stage('owned-app-service', 75, [str(app)], {'HOME': str(home), 'SHEPHERD_BROWSER_TEST_ROOT': str(browser), 'SHEPHERD_BROWSER_FEATURE_FIXTURE': str(result)})
            checks = json.loads(result.read_text())
            (output / 'fixture-checks.json').write_text(json.dumps(checks, indent=2, sort_keys=True))
            if not checks or not all(value is True for value in checks.values()):
                raise RuntimeError('Owned fixture check failed')
        if manifest() != source:
            raise RuntimeError('Source changed during validation')
        (output / 'validation.json').write_text(json.dumps({'passed': True, 'actualUIAutomation': False, 'providerCalls': False, 'ownedTemporaryRootRemoved': True, 'stages': records}, indent=2))
    except Exception:
        (output / 'validation.json').write_text(json.dumps({'passed': False, 'stages': records}, indent=2))
        raise


if __name__ == '__main__':
    main()
