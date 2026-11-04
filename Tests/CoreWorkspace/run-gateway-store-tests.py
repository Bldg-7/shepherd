#!/usr/bin/env python3
"""Real scoped workspace store over three owned official cores. No user core.
Product gateway UI/routing concurrency against arbitrary config changes is not qualified.
"""
from pathlib import Path
import argparse,hashlib,json,subprocess,sys
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--products',type=Path,required=True);p.add_argument('--official-017-archive',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
out=a.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
products=a.products.resolve();derived=products.parents[2]
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(out/'home'),'CFFIXED_USER_HOME':str(out/'home'),'TMPDIR':str(out/'tmp'),'CLANG_MODULE_CACHE_PATH':str(out/'cache'),'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer'}
source=ROOT/'Tests/CoreWorkspace/HcGatewayStoreIntegrationTests.swift'
tracked=[source,Path(__file__).resolve(),ROOT/'Tests/CoreWorkspace/run-gateway-probe.py']+sorted((ROOT/'ShepherdKit/Sources/ShepherdKit').rglob('*.swift'))
digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
hashes={str(p.relative_to(ROOT)):digest(p) for p in tracked}
assert all(p.stat().st_mtime <= (products/'ShepherdKit.o').stat().st_mtime for p in tracked if p.is_relative_to(ROOT/'ShepherdKit')),'build current Kit products first'
(out/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
maps=list((derived/'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'))
for base in [ROOT/'build/SourcePackages/checkouts',ROOT/'Vendor/Citadel',ROOT/'Vendor/swift-nio-ssh']:
 maps+=sorted(m for m in base.rglob('module.modulemap') if 'Benchmarks' not in m.parts)
objects=sorted(products.glob('*.o'));(out/'product-hashes.json').write_text(json.dumps({str(p):digest(p) for p in objects},indent=2))
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
usr=Path(env['DEVELOPER_DIR'])/'Platforms/MacOSX.platform/Developer/usr'
flags=['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-warnings-as-errors','-sdk',sdk,'-I',str(products),'-external-plugin-path',str(usr/'lib/swift/host/plugins')+'#'+str(usr/'bin/swift-plugin-server')]
for f in ['MemberImportVisibility','NonisolatedNonsendingByDefault','InferIsolatedConformances']:flags+=['-enable-upcoming-feature',f]
flags += [v for m in maps for v in ['-Xcc','-fmodule-map-file='+str(m)]]
exe=out/'gateway-store-tests'
r=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout','180','--natural-exit-grace','10','--log',str(out/'build.log'),'--',*flags,str(source),*map(str,objects),'-framework','AppKit','-framework','Security','-framework','CoreText','-framework','QuartzCore','-lz','-lsqlite3','-o',str(exe)],env=env,cwd=ROOT,timeout=220)
record=json.loads((out/'build.stage.json').read_text())
assert r.returncode==0 and record['naturalExitConfirmed'] and not record['signalsSent'] and record['cleanupVerified'],'SDK test compilation/cleanup failed: '+str(out/'build.log')
r=subprocess.run([sys.executable,str(ROOT/'Tests/CoreWorkspace/run-gateway-probe.py'),'--official-017-archive',str(a.official_017_archive),'--document-sdk-executable',str(exe),'--output',str(out/'real')],env=env,cwd=ROOT,timeout=150)
assert r.returncode==0,'owned gateway SDK/probe or cleanup failed'
assert hashes=={str(p.relative_to(ROOT)):digest(p) for p in tracked},'source changed during gate'
sdk_report=json.loads((out/'real/document-sdk.json').read_text());assert sdk_report['passed']
(out/'validation.json').write_text(json.dumps({'passed':True,'sdkChecks':sdk_report['checks'],'ownedCoreProbe':True,'officialCore':'0.1.17','productGatewayUIQualified':False,'arbitraryConcurrentConfigRoutingQualified':False},indent=2))
print('PASS real gateway document SDK:',out,flush=True)
