#!/usr/bin/env python3
"""Ctrl+B written twice to herdr's attach (SHPHRD-30): HerdrAttachInput against a
model of herdr's attach client ported from its source; Foundation only. No herdr,
process, terminal or user input."""
from pathlib import Path
import argparse,os,json,subprocess,sys,hashlib,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['home','tmp','cache']:(out/name).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
sources=['Shepherd/Terminal/HerdrAttachInput.swift','Tests/Terminal/HerdrAttachInputTests.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources+['Shepherd/Terminal/AgentTerminalViewModel.swift']},indent=2))
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 v=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and v['naturalExitConfirmed'] and not v['signalsSent'] and v['cleanupVerified'],name
stage('attach-input-build',90,['xcrun','swiftc','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library',*sources,'-o',str(out/'attach-input-tests')])
stage('attach-input-tests',20,[str(out/'attach-input-tests')])
assert 'PASS ' in (out/'attach-input-tests.log').read_text()
(out/'validation.json').write_text(json.dumps({'passed':True,'herdr':False,'herdrModel':['0.9.0','0.9.1','master','0.5.12-0.8.2'],'terminal':False,'userInput':False,'stages':2},indent=2))
