#!/usr/bin/env python3
"""Pinned loopback SSH -> actual fixed nc command -> owned UNIX capture socket.
No core, herdr, provider account, real capture service or OS permission UI.
"""
from pathlib import Path
import argparse, hashlib, json, os, shutil, subprocess, sys, tempfile, time
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--products',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
out=a.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
home=Path(tempfile.mkdtemp(prefix='ch.',dir='/tmp')).resolve()
(out/'socket-home.json').write_text(json.dumps(str(home)))
products=a.products.resolve();derived=products.parents[2]
sources=['Tests/HcBackend/ConversationSSHTests.swift']
tracked=sources+[str(f.relative_to(ROOT)) for f in (ROOT/'ShepherdKit/Sources/ShepherdKit').rglob('*.swift')]+[str(Path(__file__).resolve().relative_to(ROOT))]
digest=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
assert all((ROOT/n).stat().st_mtime <= (products/'ShepherdKit.o').stat().st_mtime for n in tracked if n.startswith('ShepherdKit/')),'build current Kit first'
hashes={n:digest(ROOT/n) for n in tracked};(out/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer','HOME':str(out/'home'),'CFFIXED_USER_HOME':str(out/'home'),'TMPDIR':str(out/'tmp'),'CLANG_MODULE_CACHE_PATH':str(out/'cache')}
profile=out/'owned-network.sb'
profile.write_text('(version 1)\n(allow default)\n(deny network*)\n(allow network* (subpath '+json.dumps(str(home))+'))\n(allow network-outbound (remote ip "localhost:*"))\n(allow network-inbound (local ip "localhost:*"))\n(deny network-outbound (literal "/private/var/run/mDNSResponder"))\n')
sandbox=['/usr/bin/sandbox-exec','-f',str(profile)]
probe='import socket,errno,sys\ns=socket.socket();s.settimeout(1)\ntry:s.connect(("203.0.113.1",9))\nexcept OSError as e:sys.exit(0 if e.errno in (errno.EPERM,errno.EACCES) else 2)\nsys.exit(1)\n'
r=subprocess.run(sandbox+[sys.executable,'-I','-S','-c',probe],env=env,capture_output=True,timeout=5)
assert r.returncode==0,'external TCP denial not confirmed'
maps=list((derived/'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'))
for base in [ROOT/'build/SourcePackages/checkouts',ROOT/'Vendor/Citadel',ROOT/'Vendor/swift-nio-ssh']:
 maps += sorted(m for m in base.rglob('module.modulemap') if 'Benchmarks' not in m.parts)
objects=sorted(str(f) for f in products.glob('*.o'))
(out/'product-hashes.json').write_text(json.dumps({n:digest(n) for n in objects},indent=2))
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
usr=Path(env['DEVELOPER_DIR'])/'Platforms/MacOSX.platform/Developer/usr'
flags=['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-warnings-as-errors','-sdk',sdk,'-I',str(products),'-external-plugin-path',str(usr/'lib/swift/host/plugins')+'#'+str(usr/'bin/swift-plugin-server')]
for feature in ['MemberImportVisibility','NonisolatedNonsendingByDefault','InferIsolatedConformances']:flags+=['-enable-upcoming-feature',feature]
flags += [x for m in maps for x in ['-Xcc','-fmodule-map-file='+str(m)]]
def stage(name,args,seconds):
 log=out/(name+'.log')
 r=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*map(str,args)],cwd=ROOT,env=env,timeout=seconds+40)
 record=json.loads(log.with_suffix('.stage.json').read_text())
 assert r.returncode==0 and record['naturalExitConfirmed'] and not record['signalsSent'] and record['cleanupVerified'],str(log)
exe=out/'capture-ssh-tests';report=out/'report.json'
stage('build',flags+sources+objects+['-framework','AppKit','-framework','Security','-framework','CoreText','-framework','QuartzCore','-lz','-lsqlite3','-o',str(exe)],180)
stage('capture',sandbox+[str(exe),str(home),str(report)],60)
r=json.loads(report.read_text());assert r['passed'] and r['ownedPIDs'] and not r['coreStarted']
for pid in r['ownedPIDs']:
 try:os.kill(pid,0)
 except ProcessLookupError:continue
 raise RuntimeError('owned nc child remains: '+str(pid))
assert hashes=={n:digest(ROOT/n) for n in tracked},'source changed during gate'
assert not (home/'Library/Application Support/com.bldg-7.shepherd/ac.sock').exists(),'capture socket left behind'
shutil.rmtree(home)
(out/'validation.json').write_text(json.dumps({'passed':True,'checks':r['checks'],'coreStarted':False,'externalNetworkDenied':True,'ownedChildrenReaped':True,'ownedSocketRemoved':True},indent=2))
print('PASS real capture SSH/socket:',out,flush=True)
