#!/usr/bin/env python3
"""The sidebar's groups put in another order by dragging their headers (SHPHRD-106): the order kept and merged with
herdr's, the gap a header is let go in, the folding while one is dragged and back after, the drag's ends (let go,
Escape, the mouse coming up or going down without the gesture), the production header drag and insertion line in a
List beside the production terminal view with pinned SwiftTerm and an owned kernel PTY, the arrow keys after a move,
and the rows' drag onto a terminal as before; never-shown windows only. No drag session, user pasteboard, user
defaults, user input, herdr, SSH or app."""
from pathlib import Path
import argparse,os,json,subprocess,sys,hashlib,platform,shutil,re
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--swiftterm-products',type=Path,required=True);args=p.parse_args();out=args.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['home','tmp','cache']:(out/name).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
products=args.swiftterm_products.resolve();bundle=products/'SwiftTerm_SwiftTerm.bundle'
if bundle.exists():shutil.copytree(bundle,out/bundle.name)
kit='ShepherdKit/Sources/ShepherdKit/'
models=[kit+'Resources.swift',kit+'Machines/Machine.swift',kit+'Agents/AgentKind.swift']+[kit+'HerdrKit/Models/'+n for n in ['JSONValue.swift','AgentModels.swift','AgentLaunchModels.swift','AgentTitleDisplay.swift','TabModels.swift','HerdrMachine.swift']]
sources=['Shepherd/Hosts/Views/BoardGroupOrder.swift','Shepherd/Terminal/HerdrItemDrag.swift','Shepherd/Terminal/TerminalHostView.swift','Shepherd/Terminal/TerminalFileGesture.swift','Shepherd/Terminal/TerminalWebLink.swift','Shepherd/FilePreview/TerminalFileHit.swift','Shepherd/FilePreview/FilePreviewLink.swift']+models+['Tests/Terminal/BoardGroupOrderTests.swift']
checked=['Shepherd/Hosts/Views/AgentBoardView.swift','ShepherdMobile/BoardView.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources+checked},indent=2))
def stage(name,seconds,args,mirrorsLog=False):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=dict(env,OS_ACTIVITY_DT_MODE='1') if mirrorsLog else env,timeout=seconds+40).returncode
 v=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and v['naturalExitConfirmed'] and not v['signalsSent'] and v['cleanupVerified'],name+': '+log.read_text(errors='replace')[-3000:]
 if mirrorsLog:
  t=log.read_text(errors='replace')
  for warning in ['Modifying state during view update','layoutSubtreeIfNeeded','reentrant']:assert warning not in t,(name,'runtime warning',warning)
stage('group-order-build',150,['xcrun','swiftc','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-I',str(products),*sources,str(products/'SwiftTerm.o'),'-framework','AppKit','-framework','QuartzCore','-framework','CoreText','-o',str(out/'group-order-tests')])
stage('group-order-tests',60,[str(out/'group-order-tests')],mirrorsLog=True)
log=(out/'group-order-tests.log').read_text()
assert 'board group order checks:' in log,'the tests ran to the end'

# Where it is wired in.
def read(n):return (ROOT/n).read_text()
b=read('Shepherd/Hosts/Views/AgentBoardView.swift')
assert '@AppStorage private var groupOrderIDs: String' in b and 'self._groupOrderIDs = AppStorage(wrappedValue: "", "AgentBoardView.groupOrder.\\(machine.id.uuidString)")' in b,'kept per Shepherd Machine'
assert 'self._collapsedGroupIDs = AppStorage(wrappedValue: "", "AgentBoardView.collapsedGroups.\\(machine.id.uuidString)")' in b,'the folded groups where they were kept'
assert '@State private var groupDrag = BoardGroupDrag()' in b and '.onDisappear { groupDrag.finish() }' in b
listing=b[b.index('    private var agentList: some View {'):b.index('    /// One herdr\'s part of the board')]
assert 'BoardGroupOrder.ordered(\n            [.host] + herdrMachineGroups.map(BoardGroup.herdrMachine),\n            by: \\.id,\n            saved: BoardGroupOrder.ids(groupOrderIDs)\n        )' in listing,'the host and herdr\'s order, then the order kept'
assert 'ForEach(listed) { item in' in listing and '.filter { !isFiltering || $0.rows.count > 0 }' in listing and '.boardGroupInsertionLine(groupDrag)' in listing
assert 'ForEach(herdrMachineGroups)' not in listing,'no group listed outside the order'
assert listing.count('if listsRows(of: ')==2 and 'isExpanded(' not in b,'both kinds of group fold by BoardGroupFolding'
assert 'BoardGroupFolding.listsRows(isCollapsed: isCollapsed(groupID), isFiltering: isFiltering, isFoldedForDrag: groupDrag.foldsRows(of: groupID))' in b
assert 'guard let order = BoardGroupOrder.moving(groupID, toGap: gap, among: shownGroupIDs, in: boardGroups.map(\\.id)) else { return }\n        groupOrderIDs = BoardGroupOrder.stored(order)' in b,'every group there is now, kept on a move'
assert len(re.findall(r'(?<![_\w])groupOrderIDs = ',b))==1 and len(re.findall(r'(?<![_\w])collapsedGroupIDs = ',b))==1,'one write each'
header=b[b.index('    private func groupHeader('):b.index('    /// A line in a group that isn\'t an agent')]
assert 'guard let collapsed = BoardGroupFolding.toggling(groupID, in: collapsedGroupIDs, isFoldingForDrag: groupDrag.isFolding) else { return }' in header and 'collapsedGroupIDs = collapsed' in header,'a click folds, not while folded for a drag'
assert 'BoardGroupFolding.looksExpanded(isCollapsed: isCollapsed(groupID), isFoldedForDrag: groupDrag.foldsRows(of: groupID))' in header
assert '.boardGroupDrag(groupID, drag: groupDrag, among: shownGroupIDs) { gap in\n            moveGroup(groupID, toGap: gap, among: shownGroupIDs)\n        }' in header
assert listing.count('groupHeader(')==2 and listing.count('among: shownGroupIDs)')>=4,'host and herdr machine headers alike'
# The rows' drag onto a terminal as SHPHRD-94 left it, and nothing of the kind on a header.
assert b.count('.herdrItemDrag(')==2 and '.onDrag' not in b and '.draggable(' not in b and 'itemProvider' not in b and '.onDrop(' not in b
d=read('Shepherd/Hosts/Views/BoardGroupOrder.swift')
for gone in ['NSPasteboard','NSItemProvider','itemProvider','onDrag','.draggable(','.onDrop(','dropDestination','pressedMouseButtons','UserDefaults']:assert gone not in d,gone
assert '.highPriorityGesture(\n                DragGesture(minimumDistance: 4, coordinateSpace: .global)' in d
assert 'drag.drag(groupID, from: value.startLocation, to: drag.pointer(), among: shown)' in d
assert 'if let gap = drag.drop(groupID, from: value.startLocation, at: drag.pointer(), among: shown) {\n                            onDrop(gap)' in d
assert 'NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseUp])' in d and 'self.cancel()\n                        return false' in d and 'return keeps ? event : nil' in d
assert '.allowsHitTesting(false)' in d and 'isolated deinit { stopWatching() }' in d
# The rows come back in steps: the move while folded, every group but the last listed, then the last.
unfold=d[d.index('    private func unfold(lastListed: String?) {'):d.index('    /// The mouse came up.')]
assert unfold.index('self.heldID = lastListed')<unfold.index('self.foldsAll = false')<unfold.rindex('DispatchQueue.main.async')<unfold.index('self.heldID = nil')
assert 'let listed = gap.flatMap { BoardGroupOrder.moving(groupID, toGap: $0, among: shown, in: shown) } ?? shown\n        finish(lastListed: listed.last)' in d
assert 'return listView.convert(window.mouseLocationOutsideOfEventStream, from: nil)' in d,'the pointer as AppKit has it'
assert '.background(BoardGroupAnchor(drag: drag, groupID: groupID))' in d and '.background(BoardGroupAnchor(drag: drag, groupID: nil))' in d
assert 'toggling' not in d[d.index('extension View {'):],'a drag never folds or unfolds'
# The iOS app lists its groups as before.
m=read('ShepherdMobile/BoardView.swift')
assert 'BoardGroupOrder' not in m and 'groupOrder' not in m and 'ForEach(monitor.herdrMachineGroups) { group in' in m
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':2,'actualSwiftTerm':True,'ownedKernelPTY':True,'ownedUnshownWindows':True,'ownedNamedPasteboards':True,
 'userDefaults':False,'userPasteboard':False,'dragSession':False,'userGUIInput':False,'herdr':False,'realSSH':False,'sourceChecks':True},indent=2))
print('PASS board group order runner: 2 stages and source checks')
