#!/usr/bin/env python3
"""Actual plain Pi → checksum-pinned official hc → product SDK/renderer.

No CLI flags, extension, session override, user config, provider login or model
prompt. All CLI networking/credential brokers and non-fixture files are denied.
This only qualifies startup/idle, event decoding and attach/detach, not workloads.
"""
from pathlib import Path
import argparse, hashlib, json, os, platform, shutil, socket, subprocess, sys, tempfile, time
sys.dont_write_bytecode = True
import cli_isolation as isolation
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'Tests/CoreProtocol'))
import core_test_artifact as artifacts

p = argparse.ArgumentParser()
p.add_argument('--official-017-archive', type=Path, required=True)
p.add_argument('--products', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--pi', type=Path, default=Path('/Users/snark/.bun/bin/pi'))
p.add_argument('--node', type=Path, default=Path('/Users/snark/.local/share/fnm/node-versions/v26.1.0/installation/bin/node'))
a = p.parse_args()
assert platform.system() == 'Darwin' and platform.machine() == 'arm64'
out = a.output.resolve(); out.mkdir(mode=0o700, parents=True, exist_ok=False)
for name in ['bin','core','work','home','tmp','cache']:
    (out/name).mkdir(mode=0o700)
products = a.products.resolve(); pi_link = a.pi.absolute(); pi = pi_link.resolve(); node = a.node.resolve()
assert pi.is_file() and node.is_file() and (products/'ShepherdKit.o').is_file()
packages = isolation.package_roots(pi)
package = next(parent for parent in [pi.parent, *pi.parents] if (parent/'package.json').is_file())
code_files = [pi, pi.with_name('cli-runtime.js'), package/'package.json', node]
for path in packages:
    code_files.append(path/'package.json')
    code_files += sorted(path.rglob('*.node'))
code_hashes = {str(path):isolation.digest(path) for path in set(code_files)}
version = json.loads((package/'package.json').read_text())['version']
artifact = artifacts.select(official_017_archive=a.official_017_archive)
binary = out/'bin/herdr-core'; core_provenance = artifacts.extract(artifact, binary)
home = out/'core'; sock = home/'c.sock'
assert len(str(sock).encode()) < 104
for name in ['state','config','runtime','tmp']:
    (home/name).mkdir(mode=0o700)
# Only ordinary terminal/transport + isolation variables. In particular there
# is no PI_OFFLINE/PI_PROGRAM_STATUS/PI_* config or provider override.
core_env = {'PATH':str(pi_link.parent)+':'+str(node.parent)+':/usr/bin:/bin:/usr/sbin:/sbin',
            'HOME':str(home),'CFFIXED_USER_HOME':str(home),'TMPDIR':str(home/'tmp'),
            'XDG_STATE_HOME':str(home/'state'),'XDG_CONFIG_HOME':str(home/'config'),
            'XDG_RUNTIME_DIR':str(home/'runtime'),'HC_SESSION':'owned','HC_SOCKET':str(sock),
            'SSH_CONNECTION':'owned-fixture-no-launchd','TERM':'xterm-256color','LANG':'en_US.UTF-8'}
assert not any(key.startswith('PI_') or any(word in key for word in ['TOKEN','SECRET','PASSWORD','API_KEY','SHEPHERD','HERDR']) for key in core_env)
plan = out/'plan.json'
plan.write_text(json.dumps({'binary':str(binary),'home':str(home),'work':str(out/'work'),
                           'output':str(out),'environment':core_env},indent=2)); plan.chmod(0o600)
env = {'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(out/'home'),
       'CFFIXED_USER_HOME':str(out/'home'),'TMPDIR':str(out/'tmp'),
       'CLANG_MODULE_CACHE_PATH':str(out/'cache'),'LANG':'en_US.UTF-8',
       'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer'}
exe = out/'plain-pi-status-tests'
profile = out/'inherited-cli.sb'
profile.write_text(isolation.profile(out,[str(node),str(pi_link),str(pi),str(binary),str(exe),'/usr/bin/env'],
                                    packages,core_runtime=True,core_home=home))
sandbox = ['/usr/bin/sandbox-exec','-f',str(profile)]
# The exact inherited policy is checked before executing any Pi or core bytes.
probe = ROOT/'Tests/CoreObservation/cli-boundary-probe.cjs'
shutil.copyfile(probe,out/'boundary-probe.cjs')
inside = out/'home/canary'; inside.write_text('nonsecret-canary')
with tempfile.TemporaryDirectory(prefix='hc-pi-plain-denied.') as raw, socket.socket() as listener:
    outside = Path(raw).resolve()/'canary'; outside.write_text('nonsecret-canary')
    listener.bind(('127.0.0.1',0)); listener.listen(1)
    checked = subprocess.run([*sandbox,str(node),str(out/'boundary-probe.cjs'),str(inside),str(outside),str(listener.getsockname()[1])],
                             env=core_env,cwd=out/'work',capture_output=True,timeout=15)
    (out/'boundary-probe.log').write_bytes(checked.stdout+checked.stderr)
    assert checked.returncode == 0 and outside.read_text() == 'nonsecret-canary', 'boundary failed; no CLI started'
    boundary = json.loads(checked.stdout); assert all(boundary.values())
(out/'boundary.json').write_text(json.dumps(boundary,indent=2))
source = 'Tests/CoreObservation/PiPlainStatusTests.swift'
presentation = ['Shepherd/ShepherdKitImport.swift','Shepherd/Hosts/Views/WorkspaceBoardPresentation.swift']
tracked = [source,*presentation,'Tests/CoreObservation/run-pi-plain-status-tests.py','Tests/CoreObservation/cli_isolation.py',
           'Tests/CoreObservation/cli-boundary-probe.cjs','Tests/CoreProtocol/core_test_artifact.py']
tracked += [str(path.relative_to(ROOT)) for path in sorted((ROOT/'ShepherdKit/Sources/ShepherdKit/CoreKit').glob('*.swift'))]
source_hashes = {name:isolation.digest(ROOT/name) for name in tracked}
assert all((ROOT/name).stat().st_mtime <= (products/'ShepherdKit.o').stat().st_mtime for name in tracked if name.startswith('ShepherdKit/')), 'build current SDK products'
(out/'source-hashes.json').write_text(json.dumps(source_hashes,indent=2))
objects = sorted(products.glob('*.o'))
product_hashes = {str(path):isolation.digest(path) for path in objects}
(out/'product-hashes.json').write_text(json.dumps(product_hashes,indent=2))
(out/'provenance.json').write_text(json.dumps({'core':core_provenance,'piVersion':version,'argv':['pi'],
    'codeHashes':code_hashes,'privateHomeAndCwd':True,'extraPiEnvironment':{},'launchdLifecycleQualified':False,
    'realProviderWorkload':False},indent=2))
for name in ['SwiftTerm_SwiftTerm.bundle','ShepherdKit_ShepherdKit.bundle']:
    shutil.copytree(products/name,out/name)
maps = list((products.parents[2]/'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'))
for base in [ROOT/'build/SourcePackages/checkouts',ROOT/'Vendor/Citadel',ROOT/'Vendor/swift-nio-ssh']:
    maps += sorted(path for path in base.rglob('module.modulemap') if 'Benchmarks' not in path.parts)
flags = ['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-warnings-as-errors','-parse-as-library',
         '-target','arm64-apple-macos26.6.2','-I',str(products)]
for feature in ['MemberImportVisibility','NonisolatedNonsendingByDefault','InferIsolatedConformances']:
    flags += ['-enable-upcoming-feature',feature]
for module in maps:
    flags += ['-Xcc','-fmodule-map-file='+str(module)]
def stage(name, seconds, command):
    log = out/(name+'.log')
    r = subprocess.run([sys.executable,'-B',str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),
                        '--natural-exit-grace','10','--log',str(log),'--',*map(str,command)],env=env,cwd=ROOT,timeout=seconds+40)
    receipt = json.loads(log.with_suffix('.stage.json').read_text())
    assert r.returncode == 0 and receipt['naturalExitConfirmed'] and receipt['cleanupVerified'] and not receipt['signalsSent'], str(log)
stage('build',180,[*flags,source,*presentation,*map(str,objects),'-framework','AppKit','-framework','Security','-framework','CoreText',
                   '-framework','QuartzCore','-lz','-lsqlite3','-o',exe])
failure = None; result = {}
try:
    stage('plain-pi',90,[*sandbox,exe,plan])
except Exception as error:
    failure = str(error)
finally:
    if sock.exists():
        stop = subprocess.run([*sandbox,str(binary),'server','stop'],env=core_env,capture_output=True,timeout=10)
        (out/'cleanup-fallback.json').write_text(json.dumps({'exitCode':stop.returncode}))
    if (out/'report.json').exists(): result = json.loads((out/'report.json').read_text())
    end = time.monotonic()+5
    while True:
        alive = []
        for pid in result.get('ownedPIDs',[]):
            try: os.kill(pid,0); alive.append(pid)
            except ProcessLookupError: pass
        if not alive and not sock.exists(): break
        if time.monotonic() >= end: raise RuntimeError('owned core/Pi retirement unconfirmed')
        time.sleep(.025)
assert source_hashes == {name:isolation.digest(ROOT/name) for name in tracked}, 'source changed'
assert code_hashes == {name:isolation.digest(Path(name)) for name in code_hashes}, 'installed code changed'
assert product_hashes == {name:isolation.digest(Path(name)) for name in product_hashes}, 'SDK/renderer products changed'
passed = failure is None and result.get('passed') is True and result.get('startupStatusQualified') is True and result.get('workspaceObservationQualified') is True
(out/'validation.json').write_text(json.dumps({'passed':passed,'piVersion':version,'coreVersion':'0.1.17',
    'argv':['pi'],'appFlagsOrEnvironmentInjected':False,'statusForced':False,'startupIdleQualified':passed,
    'workspaceObservationQualified':result.get('workspaceObservationQualified') is True,
    'workingBlockedDoneError':'NOTRUN','providerLogin':False,'modelPrompts':0,'externalNetworkDenied':True,
    'boundary':boundary,'ownedProcessesExited':bool(result.get('ownedPIDs')),'socketRemoved':not sock.exists(),
    'launchdLifecycleQualified':False,'actualGUIQualified':False,'checks':result.get('checks'),'failure':failure},indent=2))
assert passed, 'plain Pi status not qualified; inspect retained report/logs'
print('PASS actual plain Pi default startup/idle → official hc → product SDK/renderer; other workload states NOTRUN:',out)
