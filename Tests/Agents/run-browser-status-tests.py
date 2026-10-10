#!/usr/bin/env python3
from pathlib import Path
import argparse,os,subprocess,sys,json,hashlib,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
# Project only actual production enum cases/titles; authority inspection depends
# on launch/runtime services and is separately qualified by the whole app build.
definition=(ROOT/'Shepherd/Agents/AgentLaunchState.swift').read_text()
prefix=definition[:definition.index('    static func inspect(')]
projected=out/'StatusValues.swift';projected.write_text(prefix+'}\n')
sources=['Shepherd/Agents/AgentBrowserStatusBadge.swift','Tests/Agents/BrowserStatusDisplayTests.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources+['Shepherd/Agents/AgentLaunchState.swift']},indent=2))
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 j=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and j['naturalExitConfirmed'] and not j['signalsSent'] and j['cleanupVerified'],name
stage('badge-build',60,['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library',str(projected),*sources,'-o',str(out/'badge-tests')])
stage('badge-tests',20,[str(out/'badge-tests')])
board=(ROOT/'Shepherd/Hosts/Views/AgentBoardView.swift').read_text()
tab=board[board.index('    private func row(for tab:'):board.index('    /// A status dot')]
pane=board[board.index('    private func row(for agent:'):board.index('    /// A tab\'s row')]
assert 'tab.panes.count' not in tab and 'AgentBrowserStatusDisplay.tabTitle' in tab
assert 'AgentBrowserStatusBadge(status:' in pane and 'Text(AgentLaunchService.shared.status' not in pane
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':2,'tabPaneCountRemoved':True,'tabUnknownHidden':True,'paneGlobeAndColor':True,'backendAuthorityUnmodified':True},indent=2))
