#!/usr/bin/env python3
"""Owned route/CEF/Herdr/Pi qualification; no user profile or vendor API."""
import argparse, hashlib, json, os, subprocess, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--app',type=Path);p.add_argument('--pi-cli',type=Path);p.add_argument('--adapter',type=Path)
a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False,mode=0o700)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
sources=['Shepherd/Browser/CDPPolicy.swift','Shepherd/Browser/CDPRouteLeases.swift','Shepherd/Browser/CDPProxy.swift']
sources += [str(f.relative_to(ROOT)) for f in (ROOT/'Shepherd/Agents').glob('Pi*.swift')]
sources += [str(f.relative_to(ROOT)) for f in (ROOT/'Shepherd/Agents/AgentRuntime').glob('*.mjs')]
sources += ['Shepherd/Agents/AgentRuntime/pi-entry.ts','Tests/AgentBrowser/Phase3/PiRouteLeaseTests.swift','Tests/AgentBrowser/Phase3/OwnedPiNativeTool.ts','Tests/AgentBrowser/Phase3/PiNativeLifecycleTests.mjs']
(out/'source-hashes.json').write_text(json.dumps({s:hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in sources},indent=2))
records=[]
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','15','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+60).returncode
 record=json.loads(log.with_suffix('.stage.json').read_text());records.append(record)
 (out/'stages.json').write_text(json.dumps(records,indent=2))
 if code or not record['naturalExitConfirmed'] or record['signalsSent'] or not record['cleanupVerified']:raise RuntimeError(name+' failed; retained evidence')
stage('route-build',60,['/usr/bin/xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-parse-as-library',*sources[:2],'Tests/AgentBrowser/Phase3/PiRouteLeaseTests.swift','-o',str(out/'route-tests')])
stage('route-tests',15,[str(out/'route-tests')])
if a.app:
 assert a.pi_cli and os.environ.get('HERDR_ENV')=='1','explicit owned Herdr test requires Herdr context'
 (out/'binaries.json').write_text(json.dumps({str(f.resolve()):hashlib.sha256(f.resolve().read_bytes()).hexdigest() for f in [a.app,a.pi_cli]},indent=2))
 stage('native-lifecycle',170,['node','Tests/AgentBrowser/Phase3/PiNativeLifecycleTests.mjs',str(a.app.resolve()),str(out/'native'),str(a.pi_cli.resolve())]+([str(a.adapter.resolve())] if a.adapter else []))
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':len(records),'actualCEF':bool(a.app),'vendorAccounts':False},indent=2))
