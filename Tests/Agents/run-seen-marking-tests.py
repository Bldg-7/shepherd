#!/usr/bin/env python3
"""When selecting a Done agent marks it seen, and the tab.focus the client sends for it; fake transport, no herdr."""
from pathlib import Path
import argparse,os,json,hashlib,subprocess,sys,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
# The rule, with the production pane/tab/machine models and the app's default isolation.
rule=['ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/SeenMarking.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentTitleDisplay.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentModels.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/TabModels.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentLaunchModels.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/HerdrMachine.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/JSONValue.swift','Tests/Agents/SeenMarkingTests.swift']
# The real HerdrClient, built the way run-launch-tests.py --stage api builds it.
client=['Shepherd/Agents/AgentRuntime.swift','ShepherdKit/Sources/ShepherdKit/Agents/AgentKind.swift','Shepherd/Agents/AgentSavedSession.swift','Shepherd/Agents/AgentIdleStopPolicy.swift','Shepherd/Agents/AgentLaunchState.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/HerdrClient.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Transport/HerdrTransport.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Terminal/ShellQuoting.swift']+[str(p.relative_to(ROOT)) for p in sorted((ROOT/'ShepherdKit/Sources/ShepherdKit/HerdrKit/Models').glob('*.swift'))]+['Tests/Agents/SeenRequestClientTests.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sorted(set(rule+client+['Shepherd/Hosts/Views/AgentBoardView.swift']))},indent=2))
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 j=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and j['naturalExitConfirmed'] and not j['signalsSent'] and j['cleanupVerified'],name
stage('rule-build',60,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library',*rule,'-o',str(out/'rule-tests')])
stage('rule-tests',20,[str(out/'rule-tests')])
stage('client-build',90,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-swift-version','6','-parse-as-library',*client,'-o',str(out/'client-tests')])
stage('client-tests',20,[str(out/'client-tests')])
# The board asks for it on its own: the selection's request is the task's identity,
# after a wait, never refreshing the board or showing a failure.
board=(ROOT/'Shepherd/Hosts/Views/AgentBoardView.swift').read_text()
mark=board[board.index('    private func markSeen('):board.index('    private var isClosing:')]
assert '.task(id: seenRequestNow) { [request = seenRequestNow] in\n            await markSeen(request)' in board
assert 'controlActiveState == .key' in board and 'Task.sleep(for: Self.seenDelay)' in mark and 'focusTab(request.tabID, on: request.herdrMachine)' in mark
assert mark.count('isCurrentConnection(machine)')==2 and 'withTaskCancellationHandler' in mark and mark.count('client.disconnect()')==2
assert 'refreshCount' not in mark and 'actionFailure' not in mark
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':4,'productionPaneTabMachineModels':True,'actualHerdrClient':True,'fakeTransportOnly':True,'herdrOrAppTouched':False},indent=2))
