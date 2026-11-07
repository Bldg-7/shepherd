#!/usr/bin/env python3
"""DEBUG gate invariants against the actual product SDK; no core/GUI/account use."""
from pathlib import Path
import argparse,hashlib,json,subprocess,sys,shutil
R=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--products',type=Path,default=R/'build/DerivedData/Build/Products/Debug');a=p.parse_args();o=a.output.resolve();o.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(o/n).mkdir(mode=0o700)
env={'PATH':'/usr/bin:/bin','HOME':str(o/'home'),'CFFIXED_USER_HOME':str(o/'home'),'TMPDIR':str(o/'tmp'),'CLANG_MODULE_CACHE_PATH':str(o/'cache'),'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer'}
sources=['Shepherd/HcBackend/HcFixtureCloseGateTransport.swift','Tests/HcBackend/HcFixtureCloseGateTests.swift']
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
hashes={n:h(R/n) for n in sources}
(o/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
products=a.products.resolve();assert (products/'ShepherdKit.o').is_file()
assert all(v.stat().st_mtime<=(products/'ShepherdKit.o').stat().st_mtime for v in (R/'ShepherdKit/Sources').rglob('*.swift')),'build current SDK first'
objects=sorted(products.glob('*.o'));maps=list((products.parents[2]/'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'))
for base in [R/'build/SourcePackages/checkouts',R/'Vendor/Citadel',R/'Vendor/swift-nio-ssh']:
 maps+=sorted(v for v in base.rglob('module.modulemap') if 'Benchmarks' not in v.parts)
productHashes={str(v):h(v) for v in [*objects,*maps,*list((products/'ShepherdKit.swiftmodule').glob('*.swiftmodule'))]}
(o/'product-hashes.json').write_text(json.dumps(productHashes,indent=2))
shutil.copytree(products/'SwiftTerm_SwiftTerm.bundle',o/'SwiftTerm_SwiftTerm.bundle')
def stage(name,seconds,cmd):
 log=o/(name+'.log')
 subprocess.run([sys.executable,str(R/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','5','--log',str(log),'--',*cmd],cwd=R,env=env,check=True,timeout=seconds+20)
 r=json.loads(log.with_suffix('.stage.json').read_text());assert r['naturalExitConfirmed'] and r['cleanupVerified'] and not r['signalsSent']
flags=['xcrun','swiftc','-D','DEBUG','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-warnings-as-errors','-I',str(products)]
for f in ['MemberImportVisibility','NonisolatedNonsendingByDefault','InferIsolatedConformances']:flags+=['-enable-upcoming-feature',f]
for m in maps:flags+=['-Xcc','-fmodule-map-file='+str(m)]
link=[*map(str,objects),'-framework','AppKit','-framework','QuartzCore','-framework','CoreText','-framework','UserNotifications','-framework','Security','-lz','-lsqlite3']
exe=o/'close-gate-tests';stage('build',90,[*flags,*sources,*link,'-o',str(exe)]);stage('tests',20,['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(exe)])
assert hashes=={n:h(R/n) for n in sources}
assert productHashes=={n:h(Path(n)) for n in productHashes}
(o/'validation.json').write_text(json.dumps({'passed':True,'actualProductSDK':True,'actualCoreQualified':False,'guiQualified':False,'noWriteReplay':True,'strictSwift6':True},indent=2))
print('PASS close gate product-SDK component:',o)
