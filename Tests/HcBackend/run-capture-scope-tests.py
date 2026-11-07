#!/usr/bin/env python3
"""Pure hc capture provenance values; no route creation, service or CLI startup."""
from pathlib import Path
import argparse,hashlib,json,subprocess,sys
R=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();o=a.output.resolve();o.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(o/n).mkdir(mode=0o700)
env={'PATH':'/usr/bin:/bin','HOME':str(o/'home'),'CFFIXED_USER_HOME':str(o/'home'),'TMPDIR':str(o/'tmp'),'CLANG_MODULE_CACHE_PATH':str(o/'cache'),'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer'}
sources=[str(v.relative_to(R)) for v in sorted((R/'AgentProxy/Sources/AgentProxyProtocol').glob('*.swift'))]+['ShepherdKit/Sources/ShepherdKit/CoreKit/CoreTerminalID.swift','Tests/HcBackend/HcCaptureScopeTests.swift']
h=lambda n:hashlib.sha256((R/n).read_bytes()).hexdigest();hashes={n:h(n) for n in sources};(o/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
flags=['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-warnings-as-errors','-parse-as-library']
for f in ['MemberImportVisibility','NonisolatedNonsendingByDefault','InferIsolatedConformances']:flags+=['-enable-upcoming-feature',f]
records=[]
def stage(name,seconds,args):
 log=o/(name+'.log');subprocess.run([sys.executable,str(R/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','5','--log',str(log),'--',*map(str,args)],cwd=R,env=env,check=True,timeout=seconds+20)
 v=json.loads(log.with_suffix('.stage.json').read_text());assert v['naturalExitConfirmed'] and v['cleanupVerified'] and not v['signalsSent'];records.append(name)
for mode,opt in [('debug','-Onone'),('optimized','-O')]:
 exe=o/(mode+'-tests');stage(mode+'-build',90,[*flags,opt,*sources,'-o',exe]);stage(mode+'-tests',20,['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',exe])
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],env=env,text=True).strip()
stage('ios-typecheck',90,[*flags,'-sdk',sdk,'-target','arm64-apple-ios17.0-simulator','-typecheck',*sources])
assert hashes=={n:h(n) for n in sources}
(o/'validation.json').write_text(json.dumps({'passed':True,'stages':records,'pureValueValidation':True,'actualSDKTerminalRuleParity':True,'proxyOrCLIStarted':False,'routeIntegrationQualified':False,'nativeSessionAuthority':False},indent=2))
print('PASS hc capture intent/binding value gates:',o)
