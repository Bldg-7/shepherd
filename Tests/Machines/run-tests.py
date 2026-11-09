#!/usr/bin/env python3
"""Bounded machine editing tests with a fake credential store."""
from pathlib import Path
import argparse,os,json,subprocess,sys,hashlib,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['home','tmp','cache']:(out/name).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
sources=['ShepherdKit/Sources/ShepherdKit/Machines/Machine.swift','ShepherdKit/Sources/ShepherdKit/Machines/MachineStore.swift','ShepherdKit/Sources/ShepherdKit/Machines/KeychainStore.swift','Tests/Machines/MachineEditTests.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources},indent=2))
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/Support/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 v=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and v['naturalExitConfirmed'] and not v['signalsSent'] and v['cleanupVerified'],name
stage('machine-edit-build',90,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-swift-version','6','-default-isolation','MainActor','-parse-as-library',*sources,'-o',str(out/'machine-tests')])
stage('machine-edit-tests',20,[str(out/'machine-tests')])
(out/'validation.json').write_text(json.dumps({'passed':True,'realKeychainAccess':False,'networkAccess':False,'stages':2},indent=2))
