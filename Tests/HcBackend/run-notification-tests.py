#!/usr/bin/env python3
"""Native app notification coordinator over a private actual hc core.
The OS presenter and permissions are explicit in-memory stand-ins; no alerts.
"""
from pathlib import Path
import argparse, hashlib, json, os, platform, shutil, socket, subprocess, sys, time
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tests/CoreProtocol'))
import core_test_artifact as artifacts

p = argparse.ArgumentParser()
choice = artifacts.add_arguments(p)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--products', type=Path, required=True)
a = p.parse_args()
assert platform.system() == 'Darwin' and platform.machine() == 'arm64', 'pinned archive is macOS ARM64 only'
artifact = artifacts.select(a.archive, a.build_receipt, official_017_archive=a.official_017_archive)
assert artifact['version'] == '0.1.17', 'this gate requires the official 0.1.17 artifact'

def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        while b := f.read(1 << 20): h.update(b)
    return h.hexdigest()

out = a.output.resolve(); out.mkdir(mode=0o700, parents=True, exist_ok=False)
for name in ('home', 'tmp', 'cache', 'bin', 'core', 'install'):
    (out / name).mkdir(mode=0o700)
binary = out / 'bin/herdr-core'
provenance = artifacts.extract(artifact, binary)
# Stage the same bytes as `hc` for the detection positive control.
staged = out / 'install/hc'
shutil.copyfile(binary, staged); staged.chmod(0o700)
home = out / 'core'; sock = home / 'c.sock'
assert len(str(sock).encode()) < 104, 'use a shorter /tmp output path'
core_env = {'PATH': '/usr/bin:/bin', 'HOME': str(home), 'XDG_STATE_HOME': str(home/'state'),
            'XDG_CONFIG_HOME': str(home/'config'), 'XDG_RUNTIME_DIR': str(home/'runtime'),
            'HC_SESSION': 'owned', 'HC_SOCKET': str(sock), 'SSH_CONNECTION': 'owned-fixture-no-launchd',
            'LANG': 'en_US.UTF-8', 'DO_NOT_TRACK': '1'}
env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
       'DEVELOPER_DIR': os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'),
       'HOME': str(out/'home'), 'CFFIXED_USER_HOME': str(out/'home'), 'TMPDIR': str(out/'tmp'),
       'CLANG_MODULE_CACHE_PATH': str(out/'cache'), 'LANG': 'en_US.UTF-8'}
profile = out / 'private-unix-only.sb'
profile.write_text('(version 1)\n(allow default)\n(deny network*)\n(allow network* (subpath ' + json.dumps(str(home)) + '))\n')
sandbox = ['/usr/bin/sandbox-exec', '-f', str(profile)]
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0)); listener.listen(1)
    probe = "import errno,socket,sys\ns=socket.socket()\ntry: s.connect(('127.0.0.1',int(sys.argv[1])))\nexcept OSError as e: sys.exit(0 if e.errno in (errno.EPERM,errno.EACCES) else 2)\nsys.exit(1)\n"
    result = subprocess.run(sandbox + [sys.executable, '-I', '-c', probe, str(listener.getsockname()[1])], env=core_env, capture_output=True, timeout=10)
    assert result.returncode == 0, 'TCP denial canary failed'
products = a.products.resolve()
sources = ['Shepherd/ShepherdKitImport.swift','Shepherd/HcBackend/HcNotificationCoordinator.swift','Shepherd/Notifications/UserNotificationPresenter.swift']
test = 'Tests/HcBackend/HcNotificationCompositionTests.swift'
tracked = sources + [test, 'Tests/CoreProtocol/core_test_artifact.py', str(Path(__file__).resolve().relative_to(ROOT))] + [str(p.relative_to(ROOT)) for p in (ROOT/'ShepherdKit/Sources/ShepherdKit').rglob('*.swift')]
assert all((ROOT/n).stat().st_mtime <= (products/'ShepherdKit.o').stat().st_mtime for n in tracked if n.startswith('ShepherdKit/')), 'build current Kit products first'
(out/'source-hashes.json').write_text(json.dumps({n: hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in tracked}, indent=2))
(out/'provenance.json').write_text(json.dumps(provenance, indent=2))

def stage(name, seconds, args):
    log = out / (name + '.log')
    code = subprocess.run([sys.executable, str(ROOT/'Tests/Support/run-stage.py'), '--timeout', str(seconds),
                           '--natural-exit-grace', '10', '--log', str(log), '--', *map(str, args)], cwd=ROOT, env=env, timeout=seconds + 40).returncode
    receipt = json.loads(log.with_suffix('.stage.json').read_text())
    assert code == 0 and receipt['naturalExitConfirmed'] and not receipt['signalsSent'] and receipt['cleanupVerified'], name + ': ' + str(log)

flags = ['xcrun', 'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor', '-parse-as-library', '-warnings-as-errors']
for feature in ('MemberImportVisibility', 'NonisolatedNonsendingByDefault', 'InferIsolatedConformances'):
    flags += ['-enable-upcoming-feature', feature]
exe = out / 'hc-notification-composition-tests'
report = out / 'notification-report.json'
derived = products.parents[2]
maps = list((derived/'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'))
for base in [ROOT/'build/SourcePackages/checkouts',ROOT/'Vendor/Citadel',ROOT/'Vendor/swift-nio-ssh']:
    maps += sorted(m for m in base.rglob('module.modulemap') if 'Benchmarks' not in m.parts)
objects = sorted(str(p) for p in products.glob('*.o'))
sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
platform_usr=Path(env['DEVELOPER_DIR'])/'Platforms/MacOSX.platform/Developer/usr'
flags += ['-sdk',sdk,'-I',str(products),'-external-plugin-path',str(platform_usr/'lib/swift/host/plugins')+'#'+str(platform_usr/'bin/swift-plugin-server'),*[x for m in maps for x in ['-Xcc','-fmodule-map-file='+str(m)]]]
(out/'product-hashes.json').write_text(json.dumps({str(p):digest(Path(p)) for p in objects},indent=2))
stage('build', 180, flags + sources + [test,*objects,'-framework','AppKit','-framework','UserNotifications','-framework','Security','-framework','CoreText','-framework','QuartzCore','-lz','-lsqlite3','-o',str(exe)])
try:
    stage('notifications', 90, sandbox + [str(exe), str(binary), str(home), str(report)])
finally:
    if sock.exists():
        stopped = subprocess.run(sandbox + [str(binary), 'server', 'stop'], env=core_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        (out/'cleanup-status.json').write_text(json.dumps({'exitCode': stopped.returncode}))
    result = json.loads(report.read_text()) if report.exists() else {}
    pids = result.get('ownedPIDs', [])
    deadline = time.monotonic() + 5
    while True:
        alive = False
        for pid in pids:
            try: os.kill(pid, 0); alive = True
            except ProcessLookupError: pass
        if not alive and not sock.exists(): break
        if time.monotonic() >= deadline: raise RuntimeError('owned core cleanup not confirmed')
        time.sleep(0.025)
for name, expected in json.loads((out/'source-hashes.json').read_text()).items():
    assert digest(ROOT/name) == expected, 'source changed during validation: ' + name
passed = result.get('passed') is True and bool(result.get('ownedPIDs'))
(out/'validation.json').write_text(json.dumps({'passed': passed, 'realCore': artifact['version'], 'artifactVariant': artifact['variant'],
    'officialRelease': artifact['officialRelease'], 'checks': result.get('checks'), 'failure': result.get('failure'),
    'ownCoreStopped': True, 'ownSocketRemoved': True, 'ownedProcessesExited':bool(result.get('ownedPIDs')), 'launchdLifecycleQualified': False, 'isolatedHomeAndSession': True,
    'externalNetworkDenied': True, 'userCoreOrConfigTouched': False}, indent=2))
assert passed
print('PASS hc notification composition:', out)
