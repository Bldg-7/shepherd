#!/usr/bin/env python3
"""Bounded machine editing tests, fake credential store and fake SSH constructors."""
from pathlib import Path
import argparse,os,json,subprocess,sys,hashlib,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['home','tmp','cache','modules']:(out/name).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
sources=['ShepherdKit/Sources/ShepherdKit/Machines/Machine.swift','ShepherdKit/Sources/ShepherdKit/Machines/MachineStore.swift','ShepherdKit/Sources/ShepherdKit/Machines/MachineStore+Transport.swift','ShepherdKit/Sources/ShepherdKit/Machines/KeychainStore.swift','Tests/Machines/MachineEditTests.swift']
terminal_sources=['Shepherd/Terminal/AgentTerminalViewModel.swift','Shepherd/Terminal/HerdrAttachInput.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Terminal/TerminalSessionProviding.swift','Tests/Machines/TerminalFactoryTests.swift']
kit='ShepherdKit/Sources/ShepherdKit'
attach_sources=[f'{kit}/Resources.swift',f'{kit}/HerdrKit/Terminal/HerdrExecutable.swift',f'{kit}/HerdrKit/Terminal/ShellQuoting.swift',f'{kit}/HerdrKit/Terminal/LocalCommand.swift',f'{kit}/HerdrKit/Models/HerdrMachine.swift','Shepherd/Terminal/LocalAttachLaunch.swift','Tests/Machines/AttachCommandTests.swift']
callers=['Shepherd/Terminal/LocalTerminalSession.swift','Shepherd/Terminal/AgentTerminalView.swift',f'{kit}/HerdrKit/Terminal/TerminalSession.swift',f'{kit}/HerdrKit/Transport/SSHHerdrTransport.swift',f'{kit}/HerdrKit/HerdrMachineSetup/HerdrMachineSteps.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources+terminal_sources+attach_sources+callers},indent=2))
# Who attaches without mouse capture: the Mac app's attaches, local and over
# SSH; not the one-shot requests, machine setup or the iOS app.
read=lambda n:(ROOT/n).read_text()
assert 'LocalAttachLaunch.make(' in read('Shepherd/Terminal/LocalTerminalSession.swift')
assert 'withoutMouseCapture: true' in read('Shepherd/Terminal/AgentTerminalView.swift')
assert 'withoutMouseCapture: Bool = false' in read(f'{kit}/HerdrKit/Terminal/TerminalSession.swift')
assert 'HerdrExecutable.remoteAttachCommand(' in read(f'{kit}/HerdrKit/Terminal/TerminalSession.swift')
for n in [f'{kit}/HerdrKit/Transport/SSHHerdrTransport.swift',f'{kit}/HerdrKit/HerdrMachineSetup/HerdrMachineSteps.swift']+[str(x.relative_to(ROOT)) for x in sorted((ROOT/'ShepherdMobile').glob('*.swift'))]:
 assert 'withoutMouseCapture' not in read(n) and 'HERDR_CONFIG_PATH' not in read(n),n
for n in [f'{kit}/HerdrKit/Terminal/HerdrExecutable.swift','Shepherd/Terminal/LocalAttachLaunch.swift','Shepherd/Terminal/LocalTerminalSession.swift']:
 assert 'XDG_CONFIG_HOME=' not in read(n) and '"XDG_CONFIG_HOME"' not in read(n),n
# Every byte the Mac app writes to an attach goes through the view model's
# send, which writes Ctrl+B to herdr twice (HerdrAttachInput); the iOS app
# doesn't attach, and doesn't.
writers=[str(x.relative_to(ROOT)) for d in ['Shepherd','ShepherdKit','ShepherdMobile'] for x in sorted((ROOT/d).rglob('*.swift')) if 'session.write(' in x.read_text()]
assert writers==['Shepherd/Terminal/AgentTerminalViewModel.swift'],writers
vm=read('Shepherd/Terminal/AgentTerminalViewModel.swift');send=vm[vm.index('    func send(_ data: ArraySlice<UInt8>) {'):vm.index('    func resize(')]
assert vm.count('session.write(')==1 and 'let bytes = HerdrAttachInput.escaped(data, pasteOpen: &pasteOpen, takesEncodedPrefix: takesEncodedPrefix())' in send and 'session.write(Data(bytes))' in send
# Kitty and modifyOtherKeys Ctrl+B are written twice unless the host's herdr is known to be older than 0.9.0.
assert '!MachineMonitors.shared.monitor(for: machine, in: machineStore).herdrPredatesSavedMachines' in read('Shepherd/Terminal/AgentTerminalView.swift')
assert not [x for x in (ROOT/'ShepherdMobile').rglob('*.swift') if 'HerdrAttachInput' in x.read_text()]
# Enables the production conditional routing branch while keeping every actual
# transport and credential operation in explicit in-memory test doubles.
marker=out/'TestCitadel.swift';marker.write_text('public enum TestOnlyCitadelMarker {}\n')
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 v=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and v['naturalExitConfirmed'] and not v['signalsSent'] and v['cleanupVerified'],name
stage('test-module',60,['xcrun','swiftc','-emit-module','-module-name','Citadel','-parse-as-library',str(marker),'-emit-module-path',str(out/'modules/Citadel.swiftmodule')])
stage('machine-edit-build',90,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-I',str(out/'modules'),*sources,'-o',str(out/'machine-tests')])
stage('machine-edit-tests',20,[str(out/'machine-tests')])
# Only the two UI/runtime types needed by the production terminal view model.
# The production session protocol/view model themselves are compiled unchanged.
nio=out/'TestNIO.swift';nio.write_text('''public struct ByteBuffer: Sendable {
 public var readableBytesView: [UInt8] = []
 public init() {}
 public mutating func writeString(_ s: String) { readableBytesView += Array(s.utf8) }
 public mutating func writeBytes<S: Sequence>(_ bytes: S) where S.Element == UInt8 { readableBytesView += Array(bytes) }
}\n''')
term=out/'TestSwiftTerm.swift';term.write_text('''import AppKit
@MainActor public final class TerminalView: NSView {
 public private(set) var bytes: [UInt8] = []
 public func feed(byteArray: ArraySlice<UInt8>) { bytes += Array(byteArray) }
}\n''')
for module,file in [('NIOCore',nio),('SwiftTerm',term)]:
 stage(module+'-test-module',60,['xcrun','swiftc','-emit-library','-emit-module','-module-name',module,str(file),'-emit-module-path',str(out/'modules'/(module+'.swiftmodule')),'-o',str(out/'modules'/('lib'+module+'.dylib'))])
stage('terminal-factory-build',90,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-I',str(out/'modules'),'-L',str(out/'modules'),'-lNIOCore','-lSwiftTerm','-Xlinker','-rpath','-Xlinker',str(out/'modules'),*terminal_sources,'-o',str(out/'terminal-tests')])
stage('terminal-factory-tests',20,[str(out/'terminal-tests')])
# The attach command: run in this Mac's shells with a fake herdr first in
# herdr's usual locations, in HOMEs of the test's own (see the test).
attach_work=out/'attach-work';attach_work.mkdir(mode=0o700)
stage('attach-command-build',120,['xcrun','swiftc','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library',*attach_sources,'-o',str(out/'attach-command-tests')])
stage('attach-command-tests',120,[str(out/'attach-command-tests'),str(attach_work)])
(out/'validation.json').write_text(json.dumps({'passed':True,'realKeychainAccess':False,'networkAccess':False,'realHerdr':False,'ssh':False,'ctrlBWrittenTwiceToAttach':True,'stages':9},indent=2))
