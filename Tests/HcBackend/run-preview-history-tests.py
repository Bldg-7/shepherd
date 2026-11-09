#!/usr/bin/env python3
"""Actual hc preview state/request/model/owned file reads; no window/credentials/core."""
from pathlib import Path
import argparse, hashlib, json, subprocess, sys
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Tests/Terminal'))
from native_test_env import settings
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False,mode=0o700)
for leaf in ['home','tmp','cache']:(out/leaf).mkdir(mode=0o700)
env,sdk=settings(out)
files=['ShepherdKit/Sources/ShepherdKit/Resources.swift']
files += ['ShepherdKit/Sources/ShepherdKit/Pairing/'+n+'.swift' for n in ['PairingAddress','PairingAddressResolver']]
files += ['ShepherdKit/Sources/ShepherdKit/Machines/'+n+'.swift' for n in ['Machine','MachineStore','KeychainStore']]
files += ['ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/'+n+'.swift' for n in ['JSONValue','AgentModels','AgentLaunchModels','AgentTitleDisplay','TabModels','HerdrMachine']]
files += ['Shepherd/FilePreview/'+n+'.swift' for n in ['PreviewScrollAnchor','FilePreviewLink','FilePreviewReader','FilePreviewModel']]
files += [str(v.relative_to(ROOT)) for v in sorted((ROOT/'ShepherdKit/Sources/ShepherdKit/CoreKit').glob('*.swift'))]
files += ['Shepherd/HcBackend/HcPanePresentation.swift','Tests/HcBackend/HcPanePresentationTests.swift']
tracked=[ROOT/v for v in files]+[Path(__file__).resolve(),ROOT/'Tests/Terminal/native_test_env.py']
def hashes():return {str(v.relative_to(ROOT)):hashlib.sha256(v.read_bytes()).hexdigest() for v in tracked}
before=hashes();(out/'source-hashes.json').write_text(json.dumps(before,indent=2))
profile=out/'deny-network.sb';profile.write_text('(version 1)\n(allow default)\n(deny network*)\n')
stages=[]
def stage(name,command,seconds):
    log=out/(name+'.log')
    subprocess.run([sys.executable,str(ROOT/'Tests/Support/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','5','--log',str(log),'--',*map(str,command)],cwd=ROOT,env=env,timeout=seconds+30,check=True)
    r=json.loads(log.with_suffix('.stage.json').read_text());assert r['naturalExitConfirmed'] and r['cleanupVerified'] and not r['signalsSent']
    stages.append(name)
for mode,extra in [('debug',[]),('optimized',['-O'])]:
    exe=out/('preview-history-'+mode)
    stage(mode+'-build',['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-warnings-as-errors',*sdk,*extra,*files,'-o',exe],120)
    fixtures=out/('files-'+mode);fixtures.mkdir(mode=0o700)
    stage(mode+'-tests',['/usr/bin/sandbox-exec','-f',profile,exe,fixtures],20)
assert before==hashes(),'source changed during test'
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':stages,'actualStoreRequestModel':True,'physicalGUIQualified':False,'fileReads':'owned local files only','userCoreOrConfigUsed':False},indent=2))
print('PASS hc preview history: '+str(out),flush=True)
