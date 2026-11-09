#!/usr/bin/env python3
"""Rename Tab/Pane typed into the window's title: the production field, toolbar and title double-click in owned never-shown windows, wiring."""
from pathlib import Path
import argparse,json,os,hashlib,subprocess,sys,platform
R=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();o=a.output.resolve();o.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(o/n).mkdir(mode=0o700)
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(o/'home'),'CFFIXED_USER_HOME':str(o/'home'),'TMPDIR':str(o/'tmp'),'CLANG_MODULE_CACHE_PATH':str(o/'cache'),'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer'}
checks=[]
def stage(name,timeout,command,mirrorsLog=False):
 log=o/(name+'.log');subprocess.run([sys.executable,str(R/'Tests/Support/run-stage.py'),'--timeout',str(timeout),'--natural-exit-grace','10','--log',str(log),'--',*command],cwd=R,env=dict(env,OS_ACTIVITY_DT_MODE='1') if mirrorsLog else env,timeout=timeout+40,check=True)
 j=json.loads(log.with_suffix('.stage.json').read_text());assert j['naturalExitConfirmed'] and j['cleanupVerified'] and not j['signalsSent'];checks.append(name)
 # With the system log mirrored, SwiftUI's and AppKit's runtime complaints land in the log too.
 if mirrorsLog:t=log.read_text(errors='replace');assert 'Modifying state during view update' not in t and 'layoutSubtreeIfNeeded' not in t,(name,'runtime warning')
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
usr=Path(env['DEVELOPER_DIR'])/'Platforms/MacOSX.platform/Developer/usr'
flags=['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library','-sdk',sdk,'-external-plugin-path',str(usr/'lib/swift/host/plugins')+'#'+str(usr/'bin/swift-plugin-server')]
field=['Shepherd/Hosts/Views/TitleRename.swift','Shepherd/Hosts/Views/TitleRenameField.swift']
stage('field-build',90,flags+field+['Tests/Terminal/TitleRenameFieldTests.swift','-framework','AppKit','-o',str(o/'field-tests')]);stage('field-tests',30,[str(o/'field-tests')],mirrorsLog=True)
split=['Shepherd/Hosts/Views/WorkspaceDetailSplitView.swift','Shepherd/Hosts/Views/WorkspaceNavigationSplitView.swift']
watcher=['Shepherd/Hosts/Views/TitleDoubleClick.swift']
stage('toolbar-build',90,flags+field+split+watcher+['Tests/Terminal/TitleRenameToolbarTests.swift','-framework','AppKit','-o',str(o/'toolbar-tests')]);stage('toolbar-tests',30,[str(o/'toolbar-tests')],mirrorsLog=True)
locator='Shepherd/HcBackend/HcNativeTitleTarget.swift'
stage('title-target-build',90,flags+['-D','DEBUG','-warnings-as-errors',*watcher,locator,'Tests/HcBackend/HcNativeTitleTargetTests.swift','-framework','AppKit','-o',str(o/'title-target-tests')])
stage('title-target-tests',20,[str(o/'title-target-tests')])
sources=set(field+split+watcher+[locator,'Tests/HcBackend/HcNativeTitleTargetTests.swift','Shepherd/HcBackend/HcWorkspaceView.swift'])
(o/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((R/n).read_bytes()).hexdigest() for n in sorted(sources)},indent=2))
# Where it is wired in.
c=(R/'Shepherd/HcBackend/HcWorkspaceView.swift').read_text();f=(R/'Shepherd/Hosts/Views/TitleRenameField.swift').read_text()
# The title: the field in its place while a name is typed.
assert '.toolbar(removing: titleRename == nil ? nil : .title)' in c and 'ToolbarItem(id: TitleRenameToolbar.itemID, placement: .navigation) {\n                        TitleRenameField(' in c
assert '.sharedBackgroundVisibility(.hidden)' in c and '.id(session.id)' in c
assert '.frame(minWidth: TitleRenameToolbar.minimumWidth, idealWidth: TitleRenameToolbar.idealWidth, maxWidth: TitleRenameToolbar.idealWidth)' in c
assert 'TitleRenameToolbarRoom(active: titleRename != nil)' in c
assert 'enum TitleRenameToolbar {' in f and 'static let itemID = "title-rename"' in f
assert 'static let minimumWidth: CGFloat = 120' in f and 'static let idealWidth: CGFloat = 280' in f
assert 'NSWindow.didResizeNotification' in f and 'let itemView = item.view' in f
assert 'itemView.window == nil || itemView.window === window' in f
assert 'func windowDidResize(_ window: NSWindow?)' in f
assert 'guard active,\n                  let window,\n                  observedWindow === window,\n                  anchor?.window === window else { return }' in f
assert 'DispatchQueue.main.async' in f and 'generation == scheduledGeneration' in f and 'coordinator.stopObserving()' in f
# Only while the field is up, the space after it keeps the buttons at the bar's far end, where the title kept them.
shown=c[c.index('                if let session = titleRename {'):c.index('                ToolbarItem(id:"hc.preview.toggle"')]
assert c.count('ToolbarSpacer(')==1 and shown.index('.sharedBackgroundVisibility(.hidden)')<shown.index('ToolbarSpacer(.flexible, placement: .navigation)'),'the space after the field'
# What is typed is kept in from the bezel's ends, the prompt and the editor with it.
assert 'override class var cellClass: AnyClass? {\n        get { TitleRenameFieldCell.self }' in f and 'static let horizontalInset: CGFloat = 6' in f
# A double-click on the title starts a rename, alongside (not instead of) the
# title item's native-width room observer in the same background.
assert '.background {\n                ZStack {\n                    TitleDoubleClick(rename: { beginRename(currentSelection) })\n                    TitleRenameToolbarRoom(active: titleRename != nil)\n' in c
d=(R/'Shepherd/Hosts/Views/TitleDoubleClick.swift').read_text()
assert 'guard clickCount == 2, let window, window.attachedSheet == nil,' in d and 'return swallows ? nil : event' in d,'not over a sheet; only what starts a rename goes no further'
# The field: its text is only ever set when it is made; typing changes no SwiftUI state; Return/Escape only with nothing marked.
assert f.count('stringValue =')==0 and f.count('TitleRenameTextField(string: session.startText)')==1
update=f[f.index('    func updateNSView('):f.index('    static func dismantleNSView(')]
assert 'context.coordinator.parent = self' in update and 'field.' not in update,'nothing about the field changes on a refresh'
assert 'guard !session.isEnded, !textView.hasMarkedText() else { return false }' in f
assert 'session.text = textView.string' in f and 'DispatchQueue.main.async { onEnd(session, .left) }' in f
(o/'validation.json').write_text(json.dumps({'passed':True,'stages':checks,'productionFieldAndSplitViews':True,'ownedNeverShownWindows':True,'imeCompositionSimulatedThroughNSTextInputClient':True,'nativeToolbarItemAndFieldGeometry':True,'installedAppHcOrNetwork':False,'realGUIKeyboardOrFullScreen':'NOTRUN','physicalIMEOrWindowResizeGesture':'NOTRUN','titleDoubleClickSystemZoomInShownWindow':'NOTRUN','auxiliaryTitleLocatorCompositionSeam':True},indent=2))
print('PASS',len(checks),'stages and source checks')
