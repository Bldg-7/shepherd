#!/usr/bin/env python3
"""Native local foreground observations, in a private owned PTY only."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
out = p.parse_args().output.resolve()
out.mkdir(mode=0o700, parents=True, exist_ok=False)
for name in ('home', 'tmp', 'cache'):
    (out / name).mkdir(mode=0o700)
env = {'PATH':'/usr/bin:/bin:/usr/sbin:/sbin', 'HOME':str(out/'home'), 'CFFIXED_USER_HOME':str(out/'home'),
       'TMPDIR':str(out/'tmp'), 'CLANG_MODULE_CACHE_PATH':str(out/'cache'), 'LANG':'en_US.UTF-8',
       'DEVELOPER_DIR':os.environ.get('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')}
source = 'ShepherdKit/Sources/ShepherdKit/CoreKit/CoreLocalForeground.swift'
test = 'Tests/CoreObservation/CoreLocalForegroundTests.swift'
peer = 'Tests/CoreObservation/owned-foreground.py'
tracked = [source, test, peer, str(Path(__file__).resolve().relative_to(ROOT))]
hashes = {name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in tracked}
(out/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
(out/'compiler.txt').write_text(subprocess.check_output(['/usr/bin/xcrun','swiftc','--version'],env=env,text=True,timeout=30))
stages = []

def stage(name, seconds, args):
    log = out/(name+'.log')
    code = subprocess.run([sys.executable, str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),
                           '--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*map(str,args)],
                          cwd=ROOT,env=env,timeout=seconds+40).returncode
    result = json.loads(log.with_suffix('.stage.json').read_text())
    if code != 0 or not result['naturalExitConfirmed'] or result['signalsSent'] or not result['cleanupVerified']:
        raise RuntimeError(str(log))
    stages.append(name)

flags = ['/usr/bin/xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-warnings-as-errors']
for feature in ('MemberImportVisibility','NonisolatedNonsendingByDefault','InferIsolatedConformances'):
    flags += ['-enable-upcoming-feature',feature]
profile = out/'no-network.sb'
profile.write_text('(version 1)\n(allow default)\n(deny network*)\n')
reports = []
for mode, extra in [('debug',[]),('optimized',['-O'])]:
    binary = out/('foreground-'+mode)
    stage(mode+'-build',120,flags+extra+[source,test,'-o',binary])
    report = out/(mode+'-report.json')
    stage(mode+'-tests',60,['/usr/bin/sandbox-exec','-f',profile,binary,'/usr/bin/python3',ROOT/peer,out/'home',report])
    value=json.loads(report.read_text())
    if not value['passed'] or not value['ownedProcessesExited']: raise RuntimeError('fixture did not retire')
    reports.append(value)
sdk=subprocess.check_output(['/usr/bin/xcrun','--sdk','iphonesimulator','--show-sdk-path'],env=env,text=True,timeout=30).strip()
stage('ios-typecheck',120,flags+['-typecheck','-sdk',sdk,'-target',platform.machine()+'-apple-ios17.0-simulator',source])
if hashes != {name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in tracked}:
    raise RuntimeError('source changed during validation')
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':stages,'checks':[r['checks'] for r in reports],
    'privatePTY':True,'ownedProcessesExited':True,'network':False,'userCoreUsed':False,'credentialsUsed':False,
    'argvOrEnvironmentRead':False,'browserAuthorityGranted':False,'agentParityComplete':False},indent=2))
print('PASS CoreObservation:',out)
