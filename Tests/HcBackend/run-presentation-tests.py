#!/usr/bin/env python3
"""Strict pure UI-intent/revision rules, never physical GUI approval."""
from pathlib import Path
import argparse, hashlib, json, subprocess, sys
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Tests/Terminal'))
from native_test_env import settings
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False,mode=0o700)
for leaf in ['home','tmp','cache']:(out/leaf).mkdir(mode=0o700)
env,sdk_flags=settings(out)
sources=[ROOT/'Shepherd/HcBackend/HcWorkspacePresentation.swift',ROOT/'Tests/HcBackend/HcWorkspacePresentationTests.swift']
native_sources=[sources[0],ROOT/'Shepherd/HcBackend/HcTextInputOwnership.swift',ROOT/'Tests/HcBackend/HcTextInputOwnershipTests.swift']
tracked=list(dict.fromkeys(sources+native_sources+[Path(__file__).resolve(),ROOT/'Tests/Terminal/native_test_env.py']))
def hashes():return {str(v.relative_to(ROOT)):hashlib.sha256(v.read_bytes()).hexdigest() for v in tracked}
before=hashes();(out/'source-hashes.json').write_text(json.dumps(before,indent=2))
profile=out/'deny-network.sb';profile.write_text('(version 1)\n(allow default)\n(deny network*)\n')
flags=['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-warnings-as-errors']+sdk_flags
stages=[]
def stage(name,command,seconds):
    log=out/(name+'.log')
    subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),
        '--natural-exit-grace','5','--log',str(log),'--',*map(str,command)],cwd=ROOT,env=env,timeout=seconds+30,check=True)
    receipt=json.loads(log.with_suffix('.stage.json').read_text())
    assert receipt['naturalExitConfirmed'] and receipt['cleanupVerified'] and not receipt['signalsSent']
    stages.append(name)
for mode,extra in [('debug',[]),('optimized',['-O'])]:
    exe=out/('presentation-'+mode)
    stage(mode+'-build',flags+extra+list(map(str,sources))+['-o',str(exe)],90)
    stage(mode+'-tests',['/usr/bin/sandbox-exec','-f',str(profile),str(exe)],15)
native=out/'input-ownership-tests'
stage('input-ownership-build',flags+list(map(str,native_sources))+['-framework','AppKit','-o',str(native)],90)
stage('input-ownership-tests',['/usr/bin/sandbox-exec','-f',str(profile),str(native)],20)
assert before==hashes(),'source changed during tests'
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':stages,'physicalGUIQualified':False,
    'network':False,'userCoreOrConfigUsed':False},indent=2))
print('PASS scoped presentation rules: '+str(out),flush=True)
