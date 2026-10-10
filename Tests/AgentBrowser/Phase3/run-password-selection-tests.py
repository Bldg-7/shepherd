#!/usr/bin/env python3
"""Synthetic private-defaults policy tests and actual new SwiftUI source typecheck.
No app, provider CLI, browser profile, or desktop automation is invoked.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
STAGE = ROOT / 'Tests/AgentBrowser/Phase2/run-stage.py'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    output = parser.parse_args().output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    for name in ('home', 'tmp', 'cache'):
        (output / name).mkdir(mode=0o700)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
               HOME=str(output / 'home'), CFFIXED_USER_HOME=str(output / 'home'),
               TMPDIR=str(output / 'tmp'), CLANG_MODULE_CACHE_PATH=str(output / 'cache'))
    records = []
    common = ['Shepherd/CredentialBroker/CredentialBrokerContracts.swift',
              'Shepherd/CredentialBroker/CredentialBroker.swift',
              'Shepherd/CredentialBroker/Interface/CredentialCLIService.swift',
              'Shepherd/CredentialBroker/Interface/CredentialGrantView.swift',
              'Shepherd/Browser/CDPPolicy.swift',
              'Shepherd/PasswordManagers/PasswordManagerProviderID.swift',
              'Shepherd/PasswordManagers/PasswordManagerPreferences.swift',
              'Shepherd/PasswordManagers/PasswordManagerProvider.swift',
              'Shepherd/PasswordManagers/PasswordManagerCommandExecutor.swift',
              'Shepherd/PasswordManagers/BitwardenUnlockCommand.swift',
              'Shepherd/PasswordManagers/CLICredentialProvider.swift',
              'Shepherd/PasswordManagers/PasswordManagerConnectionCoordinator.swift',
              'Shepherd/HerdrKit/Terminal/LocalCommand.swift']
    feature = 'Shepherd/Browser/ShepherdBrowserFeature.swift'
    selection = 'Tests/AgentBrowser/Phase3/PasswordManagerSelectionTests.swift'
    existing = 'Tests/AgentBrowser/Phase3/ShepherdBrowserFeatureTests.swift'
    view = 'Shepherd/PasswordManagers/PasswordManagerSettingsSection.swift'
    sources = [*common, feature, selection, existing, view,
               'Shepherd/PasswordManagers/PasswordManagerConnectionSetupView.swift']
    hashes = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sources}
    (output / 'source-hashes.json').write_text(json.dumps(hashes, indent=2))

    def stage(name, seconds, command):
        log = output / (name + '.log')
        argv = [sys.executable, str(STAGE), '--timeout', str(seconds),
                '--natural-exit-grace', '10', '--log', str(log), '--', *command]
        code = subprocess.run(argv, cwd=ROOT, env=env, timeout=seconds + 40).returncode
        record = json.loads(log.with_suffix('.stage.json').read_text())
        records.append(record)
        (output / 'stages.json').write_text(json.dumps(records, indent=2))
        if code or not record['naturalExitConfirmed'] or record['signalsSent'] or not record['cleanupVerified']:
            raise RuntimeError(name + ' failed; forced cleanup is not a healthy pass')

    swift = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '6']
    binary = output / 'selection-tests'
    stage('selection-build', 60, [*swift, '-parse-as-library', feature, *common, selection, '-o', str(binary)])
    stage('selection-tests', 20, [str(binary)])
    binary = output / 'feature-tests'
    stage('feature-build', 60, [*swift, '-parse-as-library', feature, *common, existing, '-o', str(binary)])
    stage('feature-tests', 20, [str(binary)])
    stage('ui-typecheck', 60, [*swift, '-typecheck', *common, view, 'Shepherd/PasswordManagers/PasswordManagerConnectionSetupView.swift'])
    assert hashes == {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sources}
    (output / 'validation.json').write_text(json.dumps({
        'passed': True, 'syntheticDefaultsOnly': True, 'actualUIAutomation': False,
        'providerCalls': False, 'fullAppBuild': False, 'sourceUnchangedDuringValidation': True
    }, indent=2))


if __name__ == '__main__':
    main()
