#!/usr/bin/env python3
from pathlib import Path
import argparse,json,os,hashlib,subprocess,sys,platform,shutil
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--swiftterm-products',type=Path,required=True);p.add_argument('--legacy',action='store_true');p.add_argument('--restoration-red',action='store_true');p.add_argument('--collapse-red',action='store_true');p.add_argument('--width-red',action='store_true');a=p.parse_args();out=a.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
env=dict(os.environ,HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
products=a.swiftterm_products.resolve();shutil.copytree(products/'SwiftTerm_SwiftTerm.bundle',out/'SwiftTerm_SwiftTerm.bundle')
sources=['Shepherd/Hosts/Views/WorkspaceDetailSplitView.swift','Shepherd/Hosts/Views/WorkspaceNavigationSplitView.swift','Shepherd/Terminal/TerminalPaneFrame.swift','Shepherd/Terminal/TerminalFileGesture.swift','Shepherd/Terminal/TerminalWebLink.swift','Shepherd/Terminal/TerminalHostView.swift','Shepherd/FilePreview/TerminalFileHit.swift','Shepherd/FilePreview/FilePreviewLink.swift','Tests/Terminal/SidebarPeekLayoutTests.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources},indent=2))
if a.restoration_red:
 target='Shepherd/Hosts/Views/WorkspaceNavigationSplitView.swift';before=(ROOT/target).read_text();needle='                .background { WorkspaceNativeSidebarVisibility(state: state) }';assert before.count(needle)==1
 copied=out/'without-initial-native-observer.swift';copied.write_text(before.replace(needle,''));sources[sources.index(target)]=str(copied)
if a.collapse_red:
 target='Shepherd/Hosts/Views/WorkspaceNavigationSplitView.swift';before=(ROOT/target).read_text();needle='self.state.reconcileNativeSidebar(isCollapsed: collapsed, revision: revision)';assert before.count(needle)==1
 copied=out/'startup-only-native-observer.swift';copied.write_text(before.replace(needle,'if self.state.awaitsInitialNativeCollapse { '+needle+' }'));sources[sources.index(target)]=str(copied)
if a.width_red:
 target='Shepherd/Hosts/Views/WorkspaceNavigationSplitView.swift';before=(ROOT/target).read_text();needle='constraint.isActive = true';assert before.count(needle)==1
 copied=out/'without-sidebar-width-constraint.swift';copied.write_text(before.replace(needle,'_ = constraint'));sources[sources.index(target)]=str(copied)
def stage(name,seconds,command,expect_failure=False):
 log=out/(name+'.log');code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*command],cwd=ROOT,env=env,timeout=seconds+40).returncode
 j=json.loads(log.with_suffix('.stage.json').read_text());assert j['cleanupVerified']
 if expect_failure:
  message='actual revealed sidebar width must not remain a cached half-minimum drawer' if a.width_red else 'native divider collapse after explicit pin must release pin intent' if a.collapse_red else 'restored native collapse must unpin before first hover without toolbar toggles' if a.restoration_red else 'hover preview must overlay, not steal terminal width'
  assert code!=0 and not j['timedOut'] and message in log.read_text();return
 assert code==0 and j['naturalExitConfirmed'] and not j['signalsSent']
stage('sidebar-build',90,['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library','-I',str(products),*sources,str(products/'SwiftTerm.o'),'-framework','AppKit','-framework','QuartzCore','-framework','CoreText','-o',str(out/'sidebar-tests')])
stage('sidebar-tests',45,[str(out/'sidebar-tests'),str(out/'geometry.json')]+(['--legacy'] if a.legacy else [])+(['--restoration-red'] if a.restoration_red else []),expect_failure=a.legacy or a.restoration_red or a.collapse_red or a.width_red)
content=(ROOT/'Shepherd/ContentView.swift').read_text()
assert 'WorkspaceNavigationSplitView(detailMinimumWidth: detailMinimumWidth) {' in content
assert 'WorkspaceDetailSplitView(' in content, 'avoid inherited-inset redistribution in the native detail split'
assert content.count('.modifier(WorkspaceSidebarDetailLayout())') == 3, 'terminal/preview/browser HSplit children need the same native-host safe-area policy'
(out/'validation.json').write_text(json.dumps({'passed':not (a.legacy or a.restoration_red or a.collapse_red or a.width_red),'expectedWidthFailure':a.width_red,'expectedCollapseFailure':a.collapse_red,'expectedLegacyFailure':a.legacy,'expectedRestorationFailure':a.restoration_red,'automaticNativeCollapsedWithoutAnyToolbarToggle':True,'actualProductionSplitWrapper':True,'actualNativeRevealChangesVisibilityToAll':True,'explicitPinIntentSeparateFromNativeVisibility':True,'ownedUnshownWindow':True,'ownedKernelPTY':True,'realFullscreenHover':'NOTRUN','userGUIOrSSH':False,'stages':2},indent=2))
