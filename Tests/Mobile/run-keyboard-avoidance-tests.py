#!/usr/bin/env python3
"""Run the keyboard-guide bridge fixture on newly created simulators only.

The fixture checks synthetic guide geometry and UIKit guide ownership/configuration;
it explicitly does not claim to drive a floating keyboard UI.
"""
from pathlib import Path
import argparse, hashlib, json, plistlib, signal, subprocess, sys, uuid

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--runtime', default='com.apple.CoreSimulator.SimRuntime.iOS-27-0')
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, mode=0o700, exist_ok=False)
app = output / 'KeyboardAvoidanceHarness.app'
app.mkdir()
bundle = 'com.bldg7.shepherd.tests.keyboard.' + uuid.uuid4().hex
sources = ['ShepherdMobile/KeyboardAvoidance.swift', 'Tests/Mobile/KeyboardAvoidanceHarness.swift']
(output / 'source-hashes.json').write_text(json.dumps(
    {source: hashlib.sha256((ROOT / source).read_bytes()).hexdigest() for source in sources}, indent=2))
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
compile = [
    'xcrun', 'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
    '-parse-as-library', '-module-name', 'KeyboardAvoidanceHarness', '-sdk', sdk,
    '-target', 'arm64-apple-ios26.0-simulator',
    *(str(ROOT / source) for source in sources), '-framework', 'UIKit', '-framework', 'SwiftUI',
    '-o', str(app / 'KeyboardAvoidanceHarness'),
]
result = subprocess.run(compile, capture_output=True, text=True, timeout=120)
(output / 'compile.log').write_text(result.stdout + result.stderr)
assert result.returncode == 0, 'compile failed; see compile.log'
info = {
    'CFBundleExecutable': 'KeyboardAvoidanceHarness',
    'CFBundleIdentifier': bundle,
    'CFBundleName': 'Keyboard Avoidance Tests',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '1.0',
    'CFBundleVersion': '1',
    'CFBundleSupportedPlatforms': ['iPhoneSimulator'],
    'LSRequiresIPhoneOS': True,
    'MinimumOSVersion': '26.0',
    'UIDeviceFamily': [1, 2],
    'UILaunchScreen': {},
    'UIApplicationSceneManifest': {
        'UIApplicationSupportsMultipleScenes': False,
        'UISceneConfigurations': {
            'UIWindowSceneSessionRoleApplication': [{
                'UISceneConfigurationName': 'KeyboardAvoidance',
                'UISceneDelegateClassName': 'KeyboardAvoidanceHarness.KeyboardAvoidanceHarnessSceneDelegate',
            }],
        },
    },
}
(app / 'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True, timeout=30)

created = []
def stop(_signum, _frame):
    raise KeyboardInterrupt()
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
def sim(*command, timeout=120, check=True):
    return subprocess.run(['xcrun', 'simctl', *command], text=True, capture_output=True, timeout=timeout, check=check)

reports = []
try:
    for name, device_type in [
        ('iPhone', 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'),
        ('iPad', 'com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M3'),
    ]:
        udid = sim('create', 'Owned-KeyboardAvoidance-' + name + '-' + uuid.uuid4().hex[:8], device_type, args.runtime).stdout.strip()
        created.append(udid)
        (output / 'owned-devices.json').write_text(json.dumps(created))
        try:
            sim('boot', udid)
            boot = sim('bootstatus', udid, '-b', timeout=240)
            (output / (name + '-boot.log')).write_text(boot.stdout + boot.stderr)
            sim('install', udid, str(app))
            launch = sim('launch', '--console', udid, bundle, timeout=180, check=False)
            (output / (name + '-run.log')).write_text(launch.stdout + launch.stderr)
            assert launch.returncode == 0, name + ' fixture did not exit naturally; see run log'
            container = Path(sim('get_app_container', udid, bundle, 'data').stdout.strip())
            report = json.loads((container / 'Documents' / 'keyboard-avoidance-results.json').read_text())
            (output / (name + '-results.json')).write_text(json.dumps(report, indent=2))
            assert report['passed'] and report['naturalExit'], name + ' fixture failed; see results'
            reports.append(report)
            print(name + ' fixture passed', flush=True)
        finally:
            # Cleanup is defensive only; the fixture itself exits naturally.
            sim('terminate', udid, bundle, check=False)
            sim('shutdown', udid, check=False)
            sim('delete', udid)
            created.remove(udid)
            (output / 'owned-devices.json').write_text(json.dumps(created))
finally:
    for udid in created[:]:
        sim('terminate', udid, bundle, check=False)
        sim('shutdown', udid, check=False)
        sim('delete', udid, check=False)
        created.remove(udid)
    (output / 'owned-devices.json').write_text(json.dumps(created))
assert len(reports) == 2
(output / 'verification.json').write_text(json.dumps({
    'passed': True,
    'fixtures': ['iPhone', 'iPad'],
    'ownedDevicesRemoved': True,
    'existingDevicesUntouched': True,
    'naturalFixtureExit': True,
    'defensiveHelperCleanup': True,
    'actualFloatingKeyboardUI': False,
    'runtime': args.runtime,
}, indent=2))
print('PASS keyboard guide geometry/configuration/lifetime fixtures on owned iPhone and iPad simulators')
