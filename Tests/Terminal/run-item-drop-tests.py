#!/usr/bin/env python3
"""A pane's or tab's row dragged from the sidebar onto a terminal pastes its herdr ID (SHPHRD-94): the rules, the
production row modifier in a List and what its writer puts on an owned pasteboard, and the production terminal view
with pinned SwiftTerm and an owned kernel PTY taking or refusing the drop, beside File Drop, also inside an
NSHostingView; never-shown windows only. No drag session, user pasteboard, user input, herdr, SSH or app."""
from pathlib import Path
import argparse,os,json,subprocess,sys,hashlib,platform,shutil
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--swiftterm-products',type=Path,required=True);args=p.parse_args();out=args.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['home','tmp','cache']:(out/name).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
products=args.swiftterm_products.resolve();bundle=products/'SwiftTerm_SwiftTerm.bundle'
if bundle.exists():shutil.copytree(bundle,out/bundle.name)
kit='ShepherdKit/Sources/ShepherdKit/'
models=[kit+'Resources.swift',kit+'Machines/Machine.swift',kit+'Agents/AgentKind.swift']+[kit+'HerdrKit/Models/'+n for n in ['JSONValue.swift','AgentModels.swift','AgentLaunchModels.swift','AgentTitleDisplay.swift','TabModels.swift','HerdrMachine.swift']]
sources=['Shepherd/Terminal/HerdrItemDrag.swift','Shepherd/Terminal/TerminalHostView.swift','Shepherd/Terminal/TerminalFileGesture.swift','Shepherd/Terminal/TerminalWebLink.swift','Shepherd/FilePreview/TerminalFileHit.swift','Shepherd/FilePreview/FilePreviewLink.swift']+models+['Tests/Terminal/ItemDropTests.swift']
checked=['Shepherd/Hosts/Views/AgentBoardView.swift','Shepherd/Terminal/AgentTerminalView.swift','Shepherd/Terminal/TabTerminalView.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources+checked},indent=2))
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 v=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and v['naturalExitConfirmed'] and not v['signalsSent'] and v['cleanupVerified'],name+': '+log.read_text(errors='replace')[-3000:]
stage('item-drop-build',150,['xcrun','swiftc','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-I',str(products),*sources,str(products/'SwiftTerm.o'),'-framework','AppKit','-framework','QuartzCore','-framework','CoreText','-o',str(out/'item-drop-tests')])
stage('item-drop-tests',60,[str(out/'item-drop-tests')])
log=(out/'item-drop-tests.log').read_text()
assert 'item drop checks:' in log,'the tests ran to the end'

# Where it is wired in.
def read(n):return (ROOT/n).read_text()
b=read('Shepherd/Hosts/Views/AgentBoardView.swift')
pane=b[b.index('    private func row(for agent:'):b.index("    /// A tab's row")]
tab=b[b.index('    private func row(for tab:'):b.index('    /// A status dot')]
assert '.herdrItemDrag(HerdrItemDrag.Item(pane: agent, on: machine.connectionIdentity))' in pane,'a pane row drags its pane'
assert '.herdrItemDrag(HerdrItemDrag.Item(tab: tab, on: machine.connectionIdentity))' in tab,'a tab row drags its tab'
assert b.count('.herdrItemDrag(')==2 and '.onDrag' not in b and '.draggable(' not in b,'the rows only'
assert '.herdrItemDrag(' not in b[b.index('enum BoardItem:'):b.index('/// The sidebar content')]
a=read('Shepherd/Terminal/AgentTerminalView.swift')
inner=a[a.index("/// One pane's live terminal:"):]
assert 'self.connection = machine.connectionIdentity' in inner and 'self.herdrMachineID = pane.herdrMachine?.id' in inner
assert ('textDrop: viewModel.connectionState == .connected\n'
        '                ? HerdrItemDrag.terminalDrop(connection: connection, herdrMachineID: herdrMachineID) { takesItemDrag = $0 } : nil') in inner,'any live attach, whatever the File Drop setting'
assert 'takesFileDrops' not in inner[inner.index('textDrop:'):inner.index('.itemDropHighlight(')],'not gated by File Drop'
assert inner.count('.itemDropHighlight(takesItemDrag)')==1 and inner.index('.itemDropHighlight(takesItemDrag)')<inner.index('TerminalDropBanner(')
assert 'HerdrItemDrag' not in a[:a.index("/// One pane's live terminal:")],'the standalone wrapper is unchanged'
assert 'PaneTerminalView(' in read('Shepherd/Terminal/TabTerminalView.swift'),'tab mode attaches each pane through PaneTerminalView'
d=read('Shepherd/Terminal/HerdrItemDrag.swift')
assert 'registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess)' in d,'the mark is for this process only'
assert 'registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all)' in d and 'registerObject' not in d,'text as data, no NSString'
assert '.allowsHitTesting(false)' in d and 'NSPasteboard.general' not in d and 'makeFirstResponder' not in d
h=read('Shepherd/Terminal/TerminalHostView.swift')
drag=h[h.index('    override func draggingEntered('):h.index("    /// Feeds the program's output to SwiftTerm")]
assert 'makeFirstResponder' not in drag and 'sendPaste(text)' in drag and 'NSPasteboard.general' not in drag,'pasted, the keyboard left alone'
assert 'import ShepherdKit' not in h and 'HerdrItemDrag' not in h.replace('(see `HerdrItemDrag`)',''),'TerminalTextDrop knows nothing of rows'
for n in ['Config']:
 path=ROOT/n
 files=[path] if path.is_file() else list(path.rglob('*')) if path.exists() else []
 assert not any(f.is_file() and 'herdr-item' in f.read_text(errors='replace') for f in files),'no declared type'
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':2,'actualSwiftTerm':True,'ownedKernelPTY':True,'ownedUnshownWindows':True,'ownedNamedPasteboards':True,
 'userPasteboard':False,'dragSession':False,'userGUIInput':False,'herdr':False,'realSSH':False,'sourceChecks':True},indent=2))
print('PASS item drop runner: 2 stages and source checks')
