#!/usr/bin/env python3
"""The order the sidebar lists rows in, and the state_change_seq it goes by, from the snapshot; production models, no herdr."""
from pathlib import Path
import argparse,os,json,hashlib,subprocess,sys,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
# The order, with the production pane/tab/snapshot models and the app's default isolation.
sources=['ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/BoardOrder.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentTitleDisplay.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentModels.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/TabModels.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentLaunchModels.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/HerdrMachine.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/JSONValue.swift','Tests/Agents/BoardOrderTests.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources+['Shepherd/Hosts/Views/AgentBoardView.swift']},indent=2))
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 j=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and j['naturalExitConfirmed'] and not j['signalsSent'] and j['cleanupVerified'],name
stage('order-build',60,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library',*sources,'-o',str(out/'order-tests')])
stage('order-tests',20,[str(out/'order-tests')])
# The board lists each workspace's tabs and panes in that order, and has no order of its own left.
board=(ROOT/'Shepherd/Hosts/Views/AgentBoardView.swift').read_text()
rows=board[board.index('    private func rowsOfOneWorkspace('):board.index('    private func workspaceLabel(')]
assert 'ForEach(BoardOrder.tabs(tabs))' in rows and 'ForEach(BoardOrder.panes(panes))' in rows and 'sorted(' not in rows
assert 'statusPriority' not in board
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':2,'productionPaneTabSnapshotModels':True,'boardUsesBoardOrder':True,'herdrOrAppTouched':False},indent=2))
