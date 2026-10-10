#!/usr/bin/env python3
from pathlib import Path
import argparse,os,json,hashlib,subprocess,sys,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
sources=['Shepherd/HerdrKit/Models/AgentTitleDisplay.swift','Shepherd/HerdrKit/Models/AgentModels.swift','Shepherd/HerdrKit/Models/TabModels.swift','Shepherd/HerdrKit/Models/AgentLaunchModels.swift','Shepherd/HerdrKit/Models/HerdrMachine.swift','Shepherd/HerdrKit/Models/JSONValue.swift','Tests/Agents/PiTitleDisplayTests.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources},indent=2))
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 j=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and j['naturalExitConfirmed'] and not j['signalsSent'] and j['cleanupVerified'],name
stage('title-build',60,['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library',*sources,'-o',str(out/'title-tests')])
stage('title-tests',20,[str(out/'title-tests')])
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':2,'productionPaneTabSessionModels':True,'runtimeAgentKindSeam':True,'rawTitlesAndUserLabelsPreserved':True,'userPiProcessChanges':False},indent=2))
