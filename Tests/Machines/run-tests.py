#!/usr/bin/env python3
"""Bounded machine editing tests, fake credential store and fake SSH constructors."""
from pathlib import Path
import argparse,os,json,subprocess,sys,hashlib,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['home','tmp','cache','modules']:(out/name).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
sources=['Shepherd/Hosts/Models/Machine.swift','Shepherd/Hosts/Models/MachineStore.swift','Shepherd/Hosts/Models/MachineStore+Transport.swift','Shepherd/Hosts/Models/KeychainStore.swift','Tests/Machines/MachineEditTests.swift']
terminal_sources=['Shepherd/Terminal/AgentTerminalViewModel.swift','Shepherd/HerdrKit/Terminal/TerminalSessionProviding.swift','Tests/Machines/TerminalFactoryTests.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources+terminal_sources},indent=2))
# Enables the production conditional routing branch while keeping every actual
# transport and credential operation in explicit in-memory test doubles.
marker=out/'TestCitadel.swift';marker.write_text('public enum TestOnlyCitadelMarker {}\n')
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 v=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and v['naturalExitConfirmed'] and not v['signalsSent'] and v['cleanupVerified'],name
stage('test-module',60,['xcrun','swiftc','-emit-module','-module-name','Citadel','-parse-as-library',str(marker),'-emit-module-path',str(out/'modules/Citadel.swiftmodule')])
stage('machine-edit-build',90,['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-I',str(out/'modules'),*sources,'-o',str(out/'machine-tests')])
stage('machine-edit-tests',20,[str(out/'machine-tests')])
# Only the two UI/runtime types needed by the production terminal view model.
# The production session protocol/view model themselves are compiled unchanged.
nio=out/'TestNIO.swift';nio.write_text('''public struct ByteBuffer: Sendable {
 public var readableBytesView: [UInt8] = []
 public init() {}
 public mutating func writeString(_ s: String) { readableBytesView += Array(s.utf8) }
 public mutating func writeBytes<S: Sequence>(_ bytes: S) where S.Element == UInt8 { readableBytesView += Array(bytes) }
}\n''')
term=out/'TestSwiftTerm.swift';term.write_text('''@MainActor public final class TerminalView {
 public private(set) var bytes: [UInt8] = []
 public init() {}
 public func feed(byteArray: ArraySlice<UInt8>) { bytes += Array(byteArray) }
}\n''')
for module,file in [('NIOCore',nio),('SwiftTerm',term)]:
 stage(module+'-test-module',60,['xcrun','swiftc','-emit-library','-emit-module','-module-name',module,str(file),'-emit-module-path',str(out/'modules'/(module+'.swiftmodule')),'-o',str(out/'modules'/('lib'+module+'.dylib'))])
stage('terminal-factory-build',90,['xcrun','swiftc','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-I',str(out/'modules'),'-L',str(out/'modules'),'-lNIOCore','-lSwiftTerm','-Xlinker','-rpath','-Xlinker',str(out/'modules'),*terminal_sources,'-o',str(out/'terminal-tests')])
stage('terminal-factory-tests',20,[str(out/'terminal-tests')])
(out/'validation.json').write_text(json.dumps({'passed':True,'realKeychainAccess':False,'networkAccess':False,'stages':7},indent=2))
