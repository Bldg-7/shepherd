#!/usr/bin/env python3
"""Offline shared conversation client/window tests against real Core wire output.
Uses a previously validated run-core-tests output; no SSH, credentials or app.
The real SSH implementation is checked by the full ShepherdKit/app build.
"""
import argparse, hashlib, json, os, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(); p.add_argument('--output', type=Path, required=True); p.add_argument('--core', type=Path, required=True)
a = p.parse_args(); out = a.output.resolve(); core = a.core.resolve()
out.mkdir(parents=True, exist_ok=False, mode=0o700)
for name in ['home','tmp','cache']: (out/name).mkdir(mode=0o700)
env = dict(os.environ, HOME=str(out/'home'), CFFIXED_USER_HOME=str(out/'home'), TMPDIR=str(out/'tmp'), CLANG_MODULE_CACHE_PATH=str(out/'cache'))
for name, digest in json.loads((core/'source-hashes.json').read_text()).items():
    assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest() == digest, 'Core validation is stale: '+name
sources = [ROOT/'ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/HerdrLineStream.swift']
sources += sorted((ROOT/'ShepherdKit/Sources/ShepherdKit/Conversations').glob('*.swift'))
sources += [ROOT/'Tests/AgentProxy/Client/ClientTests.swift']
model_sources = [ROOT/'ShepherdMobile/CapturedConversationModel.swift', ROOT/'Tests/AgentProxy/Client/ModelTests.swift']
tracked = sources + model_sources + [Path(__file__).resolve()]
hashes = {str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest() for f in tracked}
(out/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
(out/'sandbox.sb').write_text('(version 1)\n(allow default)\n(deny network*)\n')
records = []
def stage(name, args, seconds=120):
    log = out/(name+'.log')
    result = subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'), '--timeout',str(seconds),
        '--natural-exit-grace','10','--log',str(log),'--',*map(str,args)],cwd=ROOT,env=env,timeout=seconds+40)
    record=json.loads(log.with_suffix('.stage.json').read_text()); records.append(record)
    (out/'stages.json').write_text(json.dumps(records,indent=2))
    assert result.returncode == 0 and record['naturalExitConfirmed'] and not record['signalsSent'], name+' failed'
flags=['-swift-version','5','-parse-as-library','-default-isolation','MainActor','-module-cache-path',str(out/'cache')]
for feature in ['MemberImportVisibility','NonisolatedNonsendingByDefault','InferIsolatedConformances','DisableOutwardActorInference','GlobalActorIsolatedTypesUsability','InferSendableFromCaptures']:
    flags += ['-enable-upcoming-feature',feature]
stub = out/'TransportSeam.swift'
stub.write_text('import Foundation\npublic protocol HerdrTransport: Actor { func openLineStream(endpoint: HerdrLineEndpoint, request: Data) async throws -> HerdrLineStream }\n')
shared = sources[:-1] + [stub]
for mode,opt in [('debug','-Onone'),('release','-O')]:
    build=core/mode; binary=out/(mode+'-client')
    stage(mode+'-build',['/usr/bin/xcrun','swiftc',*flags,opt,'-I',build,'-L',build,'-lAgentProxyCore','-lAgentProxyProtocol',
                        '-Xlinker','-rpath','-Xlinker',build,'-o',binary,*sources])
    stage(mode+'-tests',['/usr/bin/sandbox-exec','-f',out/'sandbox.sb',binary],30)
    print((out/(mode+'-tests.log')).read_text().strip())
    module = out/mode; module.mkdir()
    linking = ['-I',build,'-L',build,'-lAgentProxyCore','-lAgentProxyProtocol','-Xlinker','-rpath','-Xlinker',build]
    stage(mode+'-shared-module',['/usr/bin/xcrun','swiftc',*flags,opt,*linking,'-emit-module','-emit-library','-module-name','ShepherdKit',
        '-emit-module-path',module/'ShepherdKit.swiftmodule','-o',module/'libShepherdKit.dylib',*shared])
    stage(mode+'-model-build',['/usr/bin/xcrun','swiftc',*flags,opt,*linking,'-I',module,'-L',module,'-lShepherdKit',
        '-Xlinker','-rpath','-Xlinker',module,'-o',module/'ModelTests',*model_sources])
    stage(mode+'-model-tests',['/usr/bin/sandbox-exec','-f',out/'sandbox.sb',module/'ModelTests'],30)
    print((out/(mode+'-model-tests.log')).read_text().strip())
sdk=subprocess.check_output(['/usr/bin/xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
ios=out/'ios'; ios.mkdir()
core_sources=sorted((ROOT/'AgentProxy/Sources/AgentProxyCore').glob('*.swift'))
stage('ios-core-module',['/usr/bin/xcrun','swiftc','-swift-version','5','-parse-as-library','-emit-module','-module-name','AgentProxyCore',
    '-sdk',sdk,'-I',core/'ios','-target','arm64-apple-ios17.0-simulator','-module-cache-path',out/'cache',
    '-emit-module-path',ios/'AgentProxyCore.swiftmodule',*core_sources])
stage('ios-client-typecheck',['/usr/bin/xcrun','swiftc',*flags,'-typecheck','-sdk',sdk,'-target','arm64-apple-ios17.0-simulator',
                             '-I',ios,'-I',core/'ios',*sources])
assert hashes == {str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in tracked}, 'client sources changed during test'
print('PASS: bounded conversation client, window and framing Debug/-O and iOS17')
