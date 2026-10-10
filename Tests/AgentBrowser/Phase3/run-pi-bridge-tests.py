#!/usr/bin/env python3
"""Owned Unix IPC/process/MCP fixtures. No installed Pi session, model, CEF or vault."""
import argparse, hashlib, json, os
from pathlib import Path
import shutil, subprocess, sys
ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
p.add_argument('--dependencies', type=Path, required=True)
p.add_argument('--pi-cli', type=Path)
a = p.parse_args(); out = a.output.resolve(); out.mkdir(parents=True, exist_ok=False)
for name in ['home','tmp','cache','package/Sources/Bridge']:(out/name).mkdir(parents=True,mode=0o700)
env = dict(os.environ, HOME=str(out/'home'), CFFIXED_USER_HOME=str(out/'home'), TMPDIR=str(out/'tmp'),
           CLANG_MODULE_CACHE_PATH=str(out/'cache'), DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer', SWIFTCI_USE_LOCAL_DEPS='1')
sources = ['Shepherd/Agents/'+name+'.swift' for name in ['AgentRuntime','PiProcessIdentity','PiProcessLifetime','PiHostBridge','PiBridgeListener']]
sources += ['Tests/AgentBrowser/Phase3/PiBridgeIntegrationTests.swift']
identity = sources + ['Tests/AgentBrowser/Phase3/PiBridgeClientFixture.mjs','Tests/AgentBrowser/Phase3/OwnedPiBridgePTY.py','Tests/AgentBrowser/Phase3/PiBridgeObserver.ts'] + [str(f.relative_to(ROOT)) for f in (ROOT/'Shepherd/Agents/AgentRuntime').glob('pi-*')]
hashes={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in identity}
(out/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
for name in sources:shutil.copy2(ROOT/name,out/'package/Sources/Bridge'/Path(name).name)
package = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Bridge", platforms: [.macOS(.v15)], dependencies: [
    .package(path: "%s")
], targets: [.executableTarget(name: "Bridge", dependencies: [
    .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio")
], swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor"])])])
''' % (a.dependencies.resolve()/'swift-nio')
(out/'package/Package.swift').write_text(package)
records=[]
def stage(name,seconds,command):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),
                      '--natural-exit-grace','15','--log',str(log),'--',*command],cwd=ROOT,env=env,timeout=seconds+50).returncode
 record=json.loads(log.with_suffix('.stage.json').read_text());records.append(record)
 (out/'stages.json').write_text(json.dumps(records,indent=2))
 if code or not record['naturalExitConfirmed'] or record['signalsSent'] or not record['cleanupVerified']:raise RuntimeError(name+' failed')
stage('bridge-build',240,['/usr/bin/xcrun','swift','build','--package-path',str(out/'package'),'--jobs','4','--disable-automatic-resolution'])
node=shutil.which('node');assert node
if a.pi_cli:
 pi_file=a.pi_cli.resolve()
 assert pi_file.is_file()
 (out/'pi-cli.json').write_text(json.dumps({'file':str(pi_file),'sha256':hashlib.sha256(pi_file.read_bytes()).hexdigest()},indent=2))
stage('bridge-process-tests',90,[str(out/'package/.build/debug/Bridge'),str(Path(node).resolve()),str(ROOT/'Tests/AgentBrowser/Phase3/PiBridgeClientFixture.mjs'),str(ROOT/'Shepherd/Agents/AgentRuntime')] + ([str(a.pi_cli.resolve())] if a.pi_cli else []))
assert hashes=={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in identity}, 'source changed during bridge validation'
(out/'validation.json').write_text(json.dumps({'passed':True,'actualUnixIPC':True,'actualOwnedNodeProcesses':True,
    'actualBundledMCPProtocol':True,'actualPiTUI':bool(a.pi_cli),'actualCEF':'NOTRUN','realCredentials':'NOTRUN'},indent=2))
