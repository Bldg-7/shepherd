#!/usr/bin/env python3
"""Terminal file drop checks: owned files and HOMEs only, a fake ssh on PATH,
an in-memory Citadel module whose exec runs /bin/sh locally. No network, SSH
server, Keychain, user files or running app."""
from pathlib import Path
import argparse,os,json,subprocess,sys,hashlib,platform,shutil
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--swiftterm-products',type=Path);args=p.parse_args();out=args.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['home','tmp','cache','bin','modules']:(out/name).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
# The fake ssh, and the HOME it runs the far end's command under.
bin=out/'bin';shutil.copyfile(ROOT/'Tests/FileDrop/fake-ssh',bin/'ssh');(bin/'ssh').chmod(0o755)
fake_path=f'{bin}:/usr/bin:/bin'
checks=[]
def stage(name,seconds,command,extra_env=()):
 log=out/(name+'.log')
 flags=[f'--env={entry}' for entry in extra_env]
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),*flags,'--',*command],cwd=ROOT,env=env,timeout=seconds+40).returncode
 v=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and v['naturalExitConfirmed'] and not v['signalsSent'] and v['cleanupVerified'],name+': '+log.read_text(errors='replace')[-3000:]
 checks.append(name)
def fresh_work(name):
 work=out/name;work.mkdir(mode=0o700);(work/'machine-home').mkdir(mode=0o700)
 (bin/'machine-home').write_text(str(work/'machine-home'))
 for log in ['ssh-arguments.log','ssh-targets.log']:(bin/log).write_text('')
 return work
swiftc=['xcrun','swiftc','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library']
hashed=set()

# 1. Paste text, plan, names, receipts and commands; the receive script under
# /bin/sh; the host's ssh path and this Mac's machine uploader via fake ssh.
drop=['Shepherd/FileDrop/TerminalDropPaste.swift','Shepherd/FileDrop/TerminalDropUpload.swift','Shepherd/FileDrop/LocalSSHDropUploader.swift','Shepherd/HerdrKit/Terminal/LocalCommand.swift','Shepherd/HerdrKit/Terminal/HerdrExecutable.swift','Shepherd/HerdrKit/Terminal/ShellQuoting.swift','Shepherd/HerdrKit/Models/HerdrMachine.swift']
stage('drop-build',120,swiftc+drop+['Tests/FileDrop/FileDropTests.swift','-o',str(out/'drop-tests')])
work=fresh_work('drop-work')
stage('drop-tests',90,[str(out/'drop-tests'),str(work),str(bin)],[f'PATH={fake_path}'])
hashed.update(drop+['Tests/FileDrop/FileDropTests.swift','Tests/FileDrop/fake-ssh'])

# 2. The actual host uploader against an explicit in-memory Citadel module:
# its exec runs the command locally, under the test host's HOME and PATH.
modules=out/'modules'
nio=out/'TestNIO.swift';nio.write_text('''public struct ByteBuffer: Sendable {
 public let readableBytesView: [UInt8]
 public var readableBytes: Int { readableBytesView.count }
 public init<S: Sequence>(bytes: S) where S.Element == UInt8 { readableBytesView = Array(bytes) }
}\n''')
helpers=out/'TestHelpers.swift';helpers.write_text('public final class NIOLockedValueBox<T>: @unchecked Sendable { public init(_ value: T) {} }\n')
for module,file,extra in [('NIOCore',nio,[]),('NIOConcurrencyHelpers',helpers,[]),('Citadel',ROOT/'Tests/FileDrop/FakeExecModule.swift',['-I',str(modules),'-L',str(modules),'-lNIOCore'])]:
 stage(module+'-test-module',90,['xcrun','swiftc','-swift-version','6','-emit-library','-emit-module','-module-name',module,str(file),*extra,'-emit-module-path',str(modules/(module+'.swiftmodule')),'-o',str(modules/('lib'+module+'.dylib'))])
remote=['Shepherd/FileDrop/RemoteExecDropUploader.swift','Shepherd/FileDrop/TerminalDropPaste.swift','Shepherd/FileDrop/TerminalDropUpload.swift','Shepherd/HerdrKit/Terminal/LocalCommand.swift','Shepherd/HerdrKit/Terminal/HerdrExecutable.swift','Shepherd/HerdrKit/Terminal/ShellQuoting.swift','Shepherd/HerdrKit/Models/HerdrMachine.swift']
stage('remote-exec-build',120,swiftc+['-I',str(modules),'-L',str(modules),'-lCitadel','-lNIOCore','-lNIOConcurrencyHelpers','-Xlinker','-rpath','-Xlinker',str(modules),*remote,'Tests/FileDrop/RemoteExecTests.swift','-o',str(out/'remote-exec-tests')])
work=fresh_work('remote-work')
stage('remote-exec-tests',90,[str(out/'remote-exec-tests'),str(work),str(bin)])
hashed.update(remote+['Tests/FileDrop/RemoteExecTests.swift','Tests/FileDrop/FakeExecModule.swift'])

# 3. The actual controller with a fake uploader: routes, local paste, mixed
# drops, the limit, partial and drop-ending failures, stalls, leaving.
controller=['Shepherd/FileDrop/TerminalDropController.swift','Shepherd/FileDrop/TerminalDropPaste.swift','Shepherd/FileDrop/TerminalDropUpload.swift','Shepherd/HerdrKit/Transport/ConnectionFailureDescription.swift','Shepherd/HerdrKit/Terminal/LocalCommand.swift','Shepherd/HerdrKit/Terminal/HerdrExecutable.swift','Shepherd/HerdrKit/Terminal/ShellQuoting.swift','Shepherd/HerdrKit/Models/HerdrMachine.swift']
stage('controller-build',120,swiftc+controller+['Tests/FileDrop/ControllerTests.swift','-o',str(out/'controller-tests')])
work=out/'controller work';work.mkdir(mode=0o700)
stage('controller-tests',90,[str(out/'controller-tests'),str(work)])
hashed.update(controller+['Tests/FileDrop/ControllerTests.swift'])

# 4. With the project's pinned SwiftTerm: drag registration and drops on the
# actual terminal view and its SwiftUI wrapper, and the pasted bytes.
if args.swiftterm_products:
 products=args.swiftterm_products.resolve()
 bundle=products/'SwiftTerm_SwiftTerm.bundle'
 if bundle.exists():shutil.copytree(bundle,out/bundle.name)
 native=['Shepherd/Terminal/TerminalHostView.swift','Shepherd/Terminal/TerminalFileGesture.swift','Shepherd/Terminal/TerminalWebLink.swift','Shepherd/FilePreview/TerminalFileHit.swift','Shepherd/FilePreview/FilePreviewLink.swift']
 stage('drop-view-build',120,swiftc+['-I',str(products),*native,'Tests/FileDrop/DropViewTests.swift',str(products/'SwiftTerm.o'),'-framework','AppKit','-framework','QuartzCore','-framework','CoreText','-o',str(out/'drop-view-tests')])
 stage('drop-view-tests',30,[str(out/'drop-view-tests')])
 hashed.update(native+['Tests/FileDrop/DropViewTests.swift'])

(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sorted(hashed)},indent=2))
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':checks,'networkAccess':False,'realSSH':False,'userFilesRead':False,'realKeychainAccess':False,'actualSwiftTerm':bool(args.swiftterm_products)},indent=2))
print('passed:',', '.join(checks))
