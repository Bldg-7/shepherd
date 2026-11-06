#!/usr/bin/env python3
"""Pure canonical discovery/recovery text; no GUI/core/user credentials."""
from pathlib import Path
import argparse, hashlib, json, subprocess, sys
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
p.add_argument('--suite',choices=['switcher','recovery-text'],default='switcher')
a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False,mode=0o700)
for leaf in ['home','tmp','cache']:(out/leaf).mkdir(mode=0o700)
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer',
    'HOME':str(out/'home'),'CFFIXED_USER_HOME':str(out/'home'),'TMPDIR':str(out/'tmp'),
    'CLANG_MODULE_CACHE_PATH':str(out/'cache'),'LANG':'en_US.UTF-8'}
profile=out/'deny-network.sb';profile.write_text('(version 1)\n(allow default)\n(deny network*)\n')
sources=sorted((ROOT/'ShepherdKit/Sources/ShepherdKit/CoreKit').glob('*.swift'))
if a.suite=='switcher':sources += [ROOT/'Shepherd/HcBackend/HcWorkspaceSwitcherCandidates.swift',ROOT/'Tests/HcBackend/HcSwitcherCandidateTests.swift']
else:sources += [ROOT/'Shepherd/HcBackend/HcRecoveryPresentationText.swift',ROOT/'Tests/HcBackend/HcRecoveryPresentationTextTests.swift']
def hashes():return {str(v.relative_to(ROOT)):hashlib.sha256(v.read_bytes()).hexdigest() for v in sources}
before=hashes();(out/'source-hashes.json').write_text(json.dumps(before,indent=2))
flags=['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-warnings-as-errors']
for feature in ['MemberImportVisibility','NonisolatedNonsendingByDefault','InferIsolatedConformances']:
    flags += ['-enable-upcoming-feature',feature]
def stage(name,command,seconds):
    log=out/(name+'.log')
    subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),
        '--natural-exit-grace','5','--log',str(log),'--',*map(str,command)],cwd=ROOT,env=env,timeout=seconds+30,check=True)
    receipt=json.loads(log.with_suffix('.stage.json').read_text())
    assert receipt['naturalExitConfirmed'] and receipt['cleanupVerified'] and not receipt['signalsSent']
for mode,extra in [('debug',[]),('optimized',['-O'])]:
    exe=out/(a.suite+'-'+mode)
    stage(mode+'-build',flags+extra+list(map(str,sources))+['-o',str(exe)],120)
    stage(mode+'-tests',['/usr/bin/sandbox-exec','-f',str(profile),str(exe)],20)
assert before==hashes(),'source changed during tests'
(out/'validation.json').write_text(json.dumps({'passed':True,'modes':['debug','optimized'],
    'suite':a.suite,'physicalGUIQualified':False,'userCoreOrConfigUsed':False},indent=2))
print('PASS '+a.suite+' policy: '+str(out),flush=True)
