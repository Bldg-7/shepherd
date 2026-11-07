#!/usr/bin/env python3
"""New hc provenance journal only; no proxy process, CLI, listener or user state."""
from pathlib import Path
import argparse,hashlib,json,subprocess,sys
R=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--products',type=Path,required=True);a=p.parse_args();o=a.output.resolve();o.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache','module']:(o/n).mkdir(mode=0o700)
env={'PATH':'/usr/bin:/bin','HOME':str(o/'home'),'CFFIXED_USER_HOME':str(o/'home'),'TMPDIR':str(o/'tmp'),'CLANG_MODULE_CACHE_PATH':str(o/'cache'),'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer'}
products=a.products.resolve();protocol=[str(v.relative_to(R)) for v in sorted((R/'AgentProxy/Sources/AgentProxyProtocol').glob('*.swift'))]
sources=['AgentProxy/Sources/AgentProxyForwarder/StateDirectory.swift','AgentProxy/Sources/AgentProxyForwarder/HcCaptureRouteJournal.swift','Tests/HcBackend/HcCaptureRouteJournalTests.swift']
h=lambda v:hashlib.sha256(v.read_bytes()).hexdigest();hashes={n:h(R/n) for n in protocol+sources};(o/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
objects=[products/n for n in ['Crypto.o','CryptoBoringWrapper.o','CCryptoBoringSSL.o','CCryptoBoringSSLShims.o']]
maps=list((products.parents[2]/'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'))
for base in [R/'build/SourcePackages/checkouts/swift-crypto']:maps+=list(base.rglob('module.modulemap'))
productHashes={str(v):h(v) for v in [*objects,*maps]};(o/'product-hashes.json').write_text(json.dumps(productHashes,indent=2))
# Match the real AgentProxy package (Swift6, no default MainActor). No alternate
# crypto implementation or duplicate legacy protocol module is linked.
flags=['xcrun','swiftc','-swift-version','6','-parse-as-library','-warnings-as-errors']
for f in ['MemberImportVisibility','NonisolatedNonsendingByDefault','InferIsolatedConformances']:flags+=['-enable-upcoming-feature',f]
def stage(name,seconds,cmd):
 log=o/(name+'.log');subprocess.run([sys.executable,str(R/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','5','--log',str(log),'--',*map(str,cmd)],cwd=R,env=env,check=True,timeout=seconds+20)
 r=json.loads(log.with_suffix('.stage.json').read_text());assert r['naturalExitConfirmed'] and r['cleanupVerified'] and not r['signalsSent']
module=o/'module/AgentProxyProtocol.swiftmodule';obj=o/'module/AgentProxyProtocol.o'
stage('protocol-build',90,[*flags,'-whole-module-optimization','-emit-module','-emit-object','-module-name','AgentProxyProtocol',*protocol,'-emit-module-path',module,'-o',obj])
includes=['-I',str(o/'module'),'-I',str(products)]
for m in maps:includes+=['-Xcc','-fmodule-map-file='+str(m)]
for mode,opt in [('debug','-Onone'),('optimized','-O')]:
 exe=o/(mode+'-tests');stage(mode+'-build',90,[*flags,opt,*includes,*sources,obj,*objects,'-framework','CryptoKit','-framework','Security','-o',exe]);stage(mode+'-tests',20,['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',exe,o])
assert hashes=={n:h(R/n) for n in hashes};assert productHashes=={n:h(Path(n)) for n in productHashes}
(o/'validation.json').write_text(json.dumps({'passed':True,'strictSwift6':True,'actualCryptoProduct':True,'privateFilePersistence':True,'proxyOrCLIStarted':False,'liveRouteIntegrationQualified':False},indent=2))
print('PASS durable hc capture provenance journal:',o)
