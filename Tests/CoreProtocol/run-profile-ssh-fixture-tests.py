#!/usr/bin/env python3
"""Bounded private SSH sidecar lifecycle before it is admitted to a GUI gate."""
from pathlib import Path
import argparse,hashlib,json,os,shutil,socket,subprocess,sys,time
import core_test_artifact as artifacts
R=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--products',type=Path,required=True);p.add_argument('--official-017-archive',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();o=a.output.resolve();o.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache','bin','server']:(o/n).mkdir(mode=0o700)
products=a.products.resolve();binary=o/'bin/herdr-core';provenance=artifacts.extract(artifacts.select(official_017_archive=a.official_017_archive),binary)
(o/'provenance.json').write_text(json.dumps(provenance,indent=2))
env={'PATH':'/usr/bin:/bin','HOME':str(o/'home'),'CFFIXED_USER_HOME':str(o/'home'),'TMPDIR':str(o/'tmp'),'CLANG_MODULE_CACHE_PATH':str(o/'cache'),'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer'}
h=lambda v:hashlib.sha256(v.read_bytes()).hexdigest()
sources=['Tests/CoreProtocol/OwnedProfileSSHServer.swift','Tests/CoreProtocol/OwnedProfileSSHClientTests.swift']
hashes={n:h(R/n) for n in sources};(o/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
for b in ['SwiftTerm_SwiftTerm.bundle','ShepherdKit_ShepherdKit.bundle']:shutil.copytree(products/b,o/b)
maps=list((products.parents[2]/'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'))
for base in [R/'build/SourcePackages/checkouts',R/'Vendor/Citadel',R/'Vendor/swift-nio-ssh']:maps+=sorted(v for v in base.rglob('module.modulemap') if 'Benchmarks' not in v.parts)
objects=sorted(products.glob('*.o'));productHashes={str(v):h(v) for v in [*objects,*maps]};(o/'product-hashes.json').write_text(json.dumps(productHashes,indent=2))
flags=['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-I',str(products)]
for f in ['MemberImportVisibility','NonisolatedNonsendingByDefault','InferIsolatedConformances']:flags+=['-enable-upcoming-feature',f]
for m in maps:flags+=['-Xcc','-fmodule-map-file='+str(m)]
link=[*map(str,objects),'-framework','AppKit','-framework','Security','-framework','UserNotifications','-framework','CoreText','-framework','QuartzCore','-lz','-lsqlite3']
def command(name,seconds,args):return [sys.executable,str(R/'Tests/Support/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(o/(name+'.log')),'--',*map(str,args)]
def stage(name,seconds,args):
 subprocess.run(command(name,seconds,args),cwd=R,env=env,check=True,timeout=seconds+40)
 r=json.loads((o/(name+'.stage.json')).read_text());assert r['naturalExitConfirmed'] and r['cleanupVerified'] and not r['signalsSent']
server=o/'profile-server';client=o/'profile-client'
stage('server-build',180,[*flags,sources[0],*link,'-o',server]);stage('client-build',180,[*flags,sources[1],*link,'-o',client])
executableHashes={str(v):h(v) for v in [server,client]};(o/'executable-hashes.json').write_text(json.dumps(executableHashes,indent=2))
with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
profile=o/'private-network.sb';profile.write_text('(version 1)(allow default)(deny network*)(allow network* (subpath '+json.dumps(str(o/'server'))+'))(allow network-outbound (remote ip "localhost:*"))(allow network-inbound (local ip "localhost:*"))(deny network-outbound (literal "/private/var/run/mDNSResponder"))')
sandbox=['/usr/bin/sandbox-exec','-f',str(profile)]
with socket.socket() as listener:
 listener.bind(('127.0.0.1',0));listener.listen(1)
 probe="import errno,socket,sys\ns=socket.socket()\ntry:s.connect(('192.0.2.1',80))\nexcept OSError as e:sys.exit(0 if e.errno in (errno.EPERM,errno.EACCES) else 2)\nsys.exit(1)"
 subprocess.run(sandbox+[sys.executable,'-I','-c',probe],env=env,check=True,timeout=5)
controller=subprocess.Popen(command('server',60,[*sandbox,server,binary,o/'server',port,30]),cwd=R,env=env)
failure=None
try:
 end=time.monotonic()+15
 while not (o/'server/remote-ready.json').exists():
  assert controller.poll() is None and time.monotonic()<end,'owned server readiness failed'
  time.sleep(.025)
 stage('client',30,[*sandbox,client,o/'server'])
except BaseException as e:failure=e
finally:
 (o/'server/stop.request').write_text('stop owned fixture')
 try:controller.wait(timeout=20)
 except subprocess.TimeoutExpired:
  controller.terminate();controller.wait(timeout=10);failure=failure or RuntimeError('server required forced controller retirement')
 secret=o/'server/remote-profile-secret.json'
 if secret.exists():secret.unlink()
 remote=o/'server/remote core'
 if (remote/'c.sock').exists():
  core_env={'PATH':'/usr/bin:/bin','HOME':str(remote),'XDG_CONFIG_HOME':str(remote/'config'),'XDG_STATE_HOME':str(remote/'state'),'XDG_RUNTIME_DIR':str(remote/'runtime'),'HC_SESSION':'owned','HC_SOCKET':str(remote/'c.sock'),'SSH_CONNECTION':'owned-fixture-no-launchd'}
  subprocess.run(sandbox+[str(binary),'server','stop'],env=core_env,capture_output=True,timeout=10)
  failure=failure or RuntimeError('owned sidecar required emergency core retirement')
 report=json.loads((o/'server/remote-report.json').read_text()) if (o/'server/remote-report.json').exists() else {}
 end=time.monotonic()+5
 while True:
  alive=[]
  for pid in report.get('ownedPIDs',[]):
   try:os.kill(pid,0);alive.append(pid)
   except ProcessLookupError:pass
  if not alive:break
  if time.monotonic()>end:raise RuntimeError('owned core/program retirement not confirmed')
  time.sleep(.025)
assert controller.returncode==0 and report.get('passed') is True and report.get('ownedPIDs') and report.get('credentialFileRemoved') and not (o/'server/remote core/c.sock').exists()
r=json.loads((o/'server.stage.json').read_text());assert r['naturalExitConfirmed'] and r['cleanupVerified'] and not r['signalsSent']
if failure:raise failure
assert hashes=={n:h(R/n) for n in sources};assert productHashes=={n:h(Path(n)) for n in productHashes};assert executableHashes=={n:h(Path(n)) for n in executableHashes}
(o/'validation.json').write_text(json.dumps({'passed':True,'privateActualCore':True,'actualProductSDK':True,'realPinnedLoopbackSSH':True,'credentialFileRemoved':True,'ownedProcessesExited':True,'socketRemoved':True,'guiQualified':False,'userServiceOrCredentialTouched':False},indent=2))
print('PASS private profile SSH sidecar bootstrap/client/retirement:',o)
