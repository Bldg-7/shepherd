#!/usr/bin/env python3
"""Text selection on the production terminal view (SHPHRD-93): real SwiftTerm,
real AppKit events, an owned kernel PTY and never-shown windows; the view model
with an in-memory session. No user input, herdr or SSH."""
from pathlib import Path
import argparse,os,json,subprocess,sys,hashlib,platform,shutil
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--swiftterm-products',type=Path,required=True);args=p.parse_args();out=args.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['home','tmp','cache','modules']:(out/name).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
products=args.swiftterm_products.resolve();bundle=products/'SwiftTerm_SwiftTerm.bundle'
if bundle.exists():shutil.copytree(bundle,out/bundle.name)
sources=['Shepherd/Terminal/TerminalFileGesture.swift','Shepherd/Terminal/TerminalWebLink.swift','Shepherd/Terminal/TerminalHostView.swift','Shepherd/FilePreview/TerminalFileHit.swift','Shepherd/FilePreview/FilePreviewLink.swift','Shepherd/Terminal/AgentTerminalViewModel.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Terminal/TerminalSessionProviding.swift','Tests/Terminal/TerminalSelectionTests.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources+['Shepherd/Terminal/AgentTerminalView.swift']},indent=2))
# The app makes the view model feed through the view's selection keeping in
# AgentTerminalView.swift, which the test declares again for itself.
assert 'extension FocusReportingTerminalView: SelectionKeepingTerminal {}' in (ROOT/'Shepherd/Terminal/AgentTerminalView.swift').read_text()
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 v=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and v['naturalExitConfirmed'] and not v['signalsSent'] and v['cleanupVerified'],name
# The byte buffer the view model takes, in place of swift-nio's, as
# Tests/Machines/run-tests.py has it; found before the build's own NIOCore.
nio=out/'TestNIO.swift';nio.write_text('''public struct ByteBuffer: Sendable {
 public var readableBytesView: [UInt8] = []
 public init() {}
 public mutating func writeString(_ s: String) { readableBytesView += Array(s.utf8) }
 public mutating func writeBytes<S: Sequence>(_ bytes: S) where S.Element == UInt8 { readableBytesView += Array(bytes) }
}\n''')
target=platform.machine()+'-apple-macos26.6.2'
stage('NIOCore-test-module',60,['xcrun','swiftc','-target',target,'-emit-library','-emit-module','-module-name','NIOCore',str(nio),'-emit-module-path',str(out/'modules/NIOCore.swiftmodule'),'-o',str(out/'modules/libNIOCore.dylib')])
stage('selection-build',120,['xcrun','swiftc','-target',target,'-swift-version','6','-default-isolation','MainActor','-parse-as-library','-I',str(out/'modules'),'-I',str(products),'-L',str(out/'modules'),'-lNIOCore','-Xlinker','-rpath','-Xlinker',str(out/'modules'),*sources,str(products/'SwiftTerm.o'),'-framework','AppKit','-framework','QuartzCore','-framework','CoreText','-o',str(out/'selection-tests')])
stage('selection-tests',60,[str(out/'selection-tests')])
(out/'validation.json').write_text(json.dumps({'passed':True,'actualSwiftTerm':True,'ownedKernelPTY':True,'ownedUnshownWindows':True,'userGUIInput':False,'realSSH':False,'herdr':False,'pasteboardWritten':False,'stages':3},indent=2))
