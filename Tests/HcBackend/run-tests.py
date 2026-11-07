#!/usr/bin/env python3
"""Interactive hc terminal attach/session gate against a pinned official core.
No installer, PATH update, real agent, SSH, user core or user config. Network
is blocked except the private core's Unix sockets. Direct startup only (no
machine-wide launchd), via the same SSH_CONNECTION fixture marker.
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
p.add_argument('--narrow-render-tests',action='store_true',help='compare actual core and SwiftTerm at80/6 columns without a window')
p.add_argument('--products',type=Path,help='current macOS Debug products, required for narrow renderer')
p.add_argument('--renderer-products',type=Path,help='DIAGNOSTIC ONLY: separately built SwiftTerm candidate products; never changes the app pin')
a = p.parse_args()
if a.renderer_products and not a.narrow_render_tests:p.error('--renderer-products is only a diagnostic narrow-render override')
assert platform.system() == 'Darwin' and platform.machine() == 'arm64', 'pinned archive is macOS ARM64 only'
artifact = artifacts.select(a.archive, a.build_receipt, official_017_archive=a.official_017_archive)
assert artifact['version'] == '0.1.17', 'this gate requires the official 0.1.17 artifact'

def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        while b := f.read(1 << 20): h.update(b)
    return h.hexdigest()

out = a.output.resolve(); out.mkdir(mode=0o700, parents=True, exist_ok=False)
for name in ('home', 'tmp', 'cache', 'bin', 'core'):
    (out / name).mkdir(mode=0o700)
binary = out / 'bin/herdr-core'
provenance = artifacts.extract(artifact, binary)
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
sources = sorted(str(p.relative_to(ROOT)) for p in (ROOT/'ShepherdKit/Sources/ShepherdKit/CoreKit').glob('*.swift'))
test = 'Tests/HcBackend/HcNarrowRenderTests.swift' if a.narrow_render_tests else 'Tests/HcBackend/HcTerminalSessionTests.swift'
peer = 'Tests/HcBackend/attach-peer.py'
tracked = sources + [test, peer, 'Tests/CoreProtocol/core_test_artifact.py', str(Path(__file__).resolve().relative_to(ROOT))]
local_renderer = 'relativePath = Vendor/SwiftTerm;' in (ROOT/'shepherd.xcodeproj/project.pbxproj').read_text()
if a.narrow_render_tests and local_renderer:
    tracked += [str(v.relative_to(ROOT)) for v in (ROOT/'Vendor/SwiftTerm').rglob('*') if v.is_file() and '.build' not in v.parts]
    tracked += ['shepherd.xcodeproj/project.pbxproj']
(out/'source-hashes.json').write_text(json.dumps({n: hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in tracked}, indent=2))
(out/'provenance.json').write_text(json.dumps(provenance, indent=2))

def stage(name, seconds, args):
    log = out / (name + '.log')
    code = subprocess.run([sys.executable, str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'), '--timeout', str(seconds),
                           '--natural-exit-grace', '10', '--log', str(log), '--', *map(str, args)], cwd=ROOT, env=env, timeout=seconds + 40).returncode
    receipt = json.loads(log.with_suffix('.stage.json').read_text())
    assert code == 0 and receipt['naturalExitConfirmed'] and not receipt['signalsSent'] and receipt['cleanupVerified'], name + ': ' + str(log)

flags = ['xcrun', 'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor', '-parse-as-library', '-warnings-as-errors']
for feature in ('MemberImportVisibility', 'NonisolatedNonsendingByDefault', 'InferIsolatedConformances'):
    flags += ['-enable-upcoming-feature', feature]
exe = out / 'hc-terminal-session-tests'
report = out / 'core-report.json'
render_link=[]
if a.narrow_render_tests:
    assert a.products, '--products is required'
    products=a.products.resolve()
    renderer=a.renderer_products.resolve() if a.renderer_products else products
    shutil.copytree(renderer/'SwiftTerm_SwiftTerm.bundle',out/'SwiftTerm_SwiftTerm.bundle')
    sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
    derived=products.parents[2]
    maps=list((derived/'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'))
    for base in [ROOT/'build/SourcePackages/checkouts',ROOT/'Vendor/Citadel',ROOT/'Vendor/swift-nio-ssh']:
        maps += sorted(m for m in base.rglob('module.modulemap') if 'Benchmarks' not in m.parts)
    flags += ['-sdk',sdk,'-I',str(renderer),'-I',str(products),*[x for m in maps for x in ['-Xcc','-fmodule-map-file='+str(m)]]]
    objects=[v for v in products.glob('*.o') if v.name != 'SwiftTerm.o'] + [renderer/'SwiftTerm.o']
    assert all((ROOT/s).stat().st_mtime <= (products/'ShepherdKit.o').stat().st_mtime for s in sources),'build current SDK first'
    if local_renderer and not a.renderer_products:
        assert all(v.stat().st_mtime <= (renderer/'SwiftTerm.o').stat().st_mtime for v in (ROOT/'Vendor/SwiftTerm/Sources').rglob('*.swift')),'build current vendored renderer first'
    render_link=[*map(str,objects),'-framework','AppKit','-framework','QuartzCore','-framework','CoreText','-framework','UserNotifications','-framework','Security','-lz','-lsqlite3']
    (out/'renderer-product-hashes.json').write_text(json.dumps({str(v):digest(v) for v in [*objects,*maps,*list((renderer/'SwiftTerm.swiftmodule').glob('*.swiftmodule'))]},indent=2))
    sources=[] # Import the real product SDK rather than recompiling a different SSH composition.
stage('build', 120, flags + sources + [test,*render_link,'-o',str(exe)])
try:
    stage('attach', 60, sandbox + [str(exe), str(binary), str(home), str(ROOT/peer), str(report), artifact['version']])
except AssertionError as failure:
    pass
finally:
    if sock.exists():
        stopped = subprocess.run(sandbox + [str(binary), 'server', 'stop'], env=core_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        (out/'cleanup-status.json').write_text(json.dumps({'exitCode': stopped.returncode}))
    result = json.loads(report.read_text()) if report.exists() else {}
    pids = result.get('ownedPIDs', [result['corePID']] if result.get('corePID') else [])
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
if a.narrow_render_tests:
    for name,expected in json.loads((out/'renderer-product-hashes.json').read_text()).items():
        assert digest(Path(name))==expected,'renderer product changed during diagnostic: '+name
passed = result.get('passed') is True and result.get('stopAcknowledged') is True and result.get('connectChildReaped') is True and bool(pids)
if a.narrow_render_tests and local_renderer and not a.renderer_products:
    passed = passed and result.get('rendererVersion')=='1.20.0-shepherd.saved-wrap-default.1-modified'
(out/'validation.json').write_text(json.dumps({'passed': passed, 'realCore': artifact['version'], 'artifactVariant': artifact['variant'],
    'officialRelease': artifact['officialRelease'], 'checks': result.get('checks'), 'failure': result.get('failure'),
    'ownCoreStopped': True, 'ownSocketRemoved': True, 'ownedProcessesExited': bool(pids),
    'launchdLifecycleQualified': False, 'isolatedHomeAndSession': True, 'externalNetworkDenied': True,
    'userCoreOrConfigTouched': False, 'browserAuthorityUsed': False,
    'narrowRenderDiagnostic':a.narrow_render_tests,'rendererCandidate':str(a.renderer_products) if a.renderer_products else None,
    'appRendererBinding':'Vendor/SwiftTerm' if local_renderer else 'remote SwiftTerm',
    'rendererVersion':result.get('rendererVersion')}, indent=2))
assert passed
print('PASS narrow-render diagnostic:' if a.narrow_render_tests else 'PASS hc terminal attach/session:', out)
