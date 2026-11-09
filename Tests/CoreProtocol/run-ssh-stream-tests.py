#!/usr/bin/env python3
"""Owned loopback SSH + pinned core + native SwiftTerm interoperability.
Requires an already built macOS Debug products folder; never installs a core,
starts the app, reads credentials, or uses an external SSH server.
"""
from pathlib import Path
import argparse, hashlib, json, os, platform, shutil, socket, subprocess, sys, time
import core_test_artifact as artifacts
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CoreObservation'))
import candidate_artifact
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();choice=artifacts.add_arguments(p);choice.add_argument('--candidate-receipt',type=Path);p.add_argument('--products',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();out=a.output.resolve();products=a.products.resolve()
assert platform.system()=='Darwin' and platform.machine()=='arm64'
def digest(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  while b:=f.read(1<<20):h.update(b)
 return h.hexdigest()
if a.candidate_receipt:
 candidate_binary, candidate_receipt=candidate_artifact.select(a.candidate_receipt)
 artifact={'variant':candidate_receipt['variant'],'officialRelease':False,'version':'0.1.16','resizeNotifications':True}
else:
 artifact=artifacts.select(a.archive,a.build_receipt,official_017_archive=a.official_017_archive)
out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache','bin','core home']:(out/n).mkdir(mode=0o700)
binary=out/'bin/herdr-core'
if a.candidate_receipt:
 with candidate_binary.open('rb') as src,binary.open('xb') as dst:shutil.copyfileobj(src,dst)
 candidate_artifact.require(digest(binary)==candidate_receipt['binarySHA256'],'copied candidate changed')
 binary.chmod(0o700);provenance=candidate_receipt
else:
 provenance=artifacts.extract(artifact,binary)
core=out/'core home';sock=core/'c.sock';assert len(str(sock).encode())<104
core_env={'PATH':'/usr/bin:/bin','HOME':str(core),'XDG_STATE_HOME':str(core/'state'),'XDG_CONFIG_HOME':str(core/'config'),
 'SSH_CONNECTION':'owned-fixture-no-launchd', # Skip machine-wide launchd jobs; not a lifecycle qualification.
 'XDG_RUNTIME_DIR':str(core/'runtime'),'HC_SESSION':'owned','HC_SOCKET':str(sock),'LANG':'en_US.UTF-8','DO_NOT_TRACK':'1'}
env={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'DEVELOPER_DIR':os.environ.get('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer'),
 'HOME':str(out/'home'),'CFFIXED_USER_HOME':str(out/'home'),'TMPDIR':str(out/'tmp'),'CLANG_MODULE_CACHE_PATH':str(out/'cache'),'LANG':'en_US.UTF-8'}
profile=out/'owned-network.sb'
profile.write_text('(version 1)\n(allow default)\n(deny network*)\n(allow network* (subpath '+json.dumps(str(core))+'))\n'
 '(allow network-outbound (remote ip "localhost:*"))\n(allow network-inbound (local ip "localhost:*"))\n'
 '(deny network-outbound (literal "/private/var/run/mDNSResponder"))\n')
sandbox=['/usr/bin/sandbox-exec','-f',str(profile)]
sources=['Tests/CoreProtocol/SSHStreamIntegrationTests.swift','Tests/CoreProtocol/terminal-peer.py']
tracked=sources+['Tests/CoreObservation/candidate_artifact.py','Tests/CoreProtocol/core_test_artifact.py',str(Path(__file__).resolve().relative_to(ROOT))]+[str(p.relative_to(ROOT)) for p in (ROOT/'ShepherdKit/Sources/ShepherdKit/CoreKit').glob('*.swift')]
hashes={n:digest(ROOT/n) for n in tracked};(out/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
# Retain the actual linked artifact provenance; build products are not rebuilt
# by this runner. Reject products older than these production sources.
core_sources=[ROOT/n for n in tracked if n.startswith('ShepherdKit/')]
assert all(p.stat().st_mtime <= (products/'ShepherdKit.o').stat().st_mtime for p in core_sources), 'build Shepherd first'
(out/'product-hashes.json').write_text(json.dumps({n:digest(products/n) for n in ['ShepherdKit.o','SwiftTerm.o','NIOSSH.o']},indent=2))
(out/'provenance.json').write_text(json.dumps(provenance,indent=2))
for bundle in ['SwiftTerm_SwiftTerm.bundle','ShepherdKit_ShepherdKit.bundle']:
 shutil.copytree(products/bundle,out/bundle)
derived=products.parents[2]
maps=list((derived/'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'))
for base in [ROOT/'build/SourcePackages/checkouts',ROOT/'Vendor/Citadel',ROOT/'Vendor/swift-nio-ssh']:
 maps+=sorted(m for m in base.rglob('module.modulemap') if 'Benchmarks' not in m.parts)
objects=sorted(str(p) for p in products.glob('*.o'))
assert any(p.endswith('/ShepherdKit.o') for p in objects) and any(p.endswith('/SwiftTerm.o') for p in objects)
records=[]
def stage(name,seconds,cmd):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/Support/run-stage.py'),'--timeout',str(seconds),
  '--natural-exit-grace','10','--log',str(log),'--',*cmd],cwd=ROOT,env=env,timeout=seconds+40).returncode
 r=json.loads(log.with_suffix('.stage.json').read_text());records.append(r)
 assert code==0 and r['naturalExitConfirmed'] and not r['signalsSent'] and r['cleanupVerified'],str(log)
exe=out/'ssh-stream-tests'
flags=['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-target','arm64-apple-macos26.6.2',
 '-I',str(products),*[x for m in maps for x in ['-Xcc','-fmodule-map-file='+str(m)]]]
for f in ['MemberImportVisibility','NonisolatedNonsendingByDefault','InferIsolatedConformances']:flags+=['-enable-upcoming-feature',f]
stage('build',180,flags+[sources[0],*objects,'-framework','AppKit','-framework','Security','-framework','CoreText','-framework','QuartzCore','-lz','-lsqlite3','-o',str(exe)])
report=out/'report.json'
failure=None
try:
 stage('ssh-streams',90,sandbox+[str(exe),str(binary),str(core),str(ROOT/sources[1]),str(report),'resize-enabled' if artifact.get('resizeNotifications',False) else 'resize-disabled',artifact['version']])
except AssertionError as error:
 failure=error
finally:
 if sock.exists():
  stopped=subprocess.run(sandbox+[str(binary),'server','stop'],env=core_env,capture_output=True,timeout=10)
  (out/'cleanup.json').write_text(json.dumps({'exitCode':stopped.returncode}))
 result=json.loads(report.read_text()) if report.exists() else {}
 end=time.monotonic()+5
 while True:
  alive=False
  for pid in result.get('ownedPIDs', [result['corePID']] if result.get('corePID') else []):
   try:os.kill(pid,0);alive=True
   except ProcessLookupError:pass
  if not alive and not sock.exists():break
  if time.monotonic()>end:raise RuntimeError('owned core cleanup unconfirmed')
  time.sleep(.025)
assert hashes=={n:digest(ROOT/n) for n in tracked},'sources changed during validation'
runtime_log=(out/'ssh-streams.log').read_text(errors='replace')
assert 'Cannot schedule tasks on an EventLoop that has already shut down' not in runtime_log, 'late work after SSH cleanup'
passed=failure is None and result.get('passed') is True and result.get('stopAcknowledged') is True
(out/'validation.json').write_text(json.dumps({'passed':passed,'ssh':'owned-loopback','nativeSwiftTerm':True,'realCore':artifact['version'],'launchdLifecycleQualified':False,'artifactVariant':artifact['variant'],'officialRelease':artifact['officialRelease'],
 'userCoreOrCredentialsTouched':False,'checks':result.get('checks'),'coreStopped':True,'socketRemoved':True,'ownedProcessesExited':bool(result.get('ownedPIDs')),
 'osc8FirstPaint':result.get('osc8FirstPaint'),'osc8Live':result.get('osc8Live'),'osc8Reconnect':result.get('osc8Reconnect'),
 'factoryDiscoveryExecuted':result.get('factoryDiscoveryExecuted',False),'functionalChecksCompleted':result.get('functionalChecksCompleted',False),
 'productOwnerProfileSwitch':result.get('productOwnerProfileSwitch',False),'productOwnerHostKeyApproval':result.get('productOwnerHostKeyApproval',False),
 'blocker':'SHPHRD-157' if result.get('osc8FirstPaint') is False or result.get('osc8Reconnect') is False else None},indent=2))
if failure:raise failure
assert passed
print('PASS SSH/streams/SwiftTerm integration:',out)
