#!/usr/bin/env python3
"""Actual mouse routing into an owned kernel PTY; no user input or SSH."""
from pathlib import Path
import argparse,os,json,subprocess,sys,hashlib,platform,shutil
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--swiftterm-products',type=Path,required=True);args=p.parse_args();out=args.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['home','tmp','cache']:(out/name).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
products=args.swiftterm_products.resolve();bundle=products/'SwiftTerm_SwiftTerm.bundle'
if bundle.exists():shutil.copytree(bundle,out/bundle.name)
sources=['Shepherd/Terminal/TerminalFileGesture.swift','Shepherd/Terminal/TerminalHostView.swift','Shepherd/FilePreview/TerminalFileHit.swift','Shepherd/FilePreview/FilePreviewLink.swift','Tests/Terminal/FilePointerRoutingTests.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources},indent=2))
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 v=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and v['naturalExitConfirmed'] and not v['signalsSent'] and v['cleanupVerified'],name
stage('pointer-build',90,['xcrun','swiftc','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-I',str(products),*sources,str(products/'SwiftTerm.o'),'-framework','AppKit','-framework','QuartzCore','-framework','CoreText','-o',str(out/'pointer-tests')])
stage('pointer-tests',30,[str(out/'pointer-tests')])
(out/'validation.json').write_text(json.dumps({'passed':True,'actualSwiftTerm':True,'ownedKernelPTY':True,'ownedUnshownWindow':True,'userGUIInput':False,'realSSH':False,'stages':2},indent=2))
