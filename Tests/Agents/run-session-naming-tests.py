#!/usr/bin/env python3
"""A pane renamed in the app, passed on to the session of the agent in it (SHPHRD-95): the name, the command, the
verdicts, the editor, the names waiting and the attempts against a fake herdr, Pi's extension against a fake bridge, and
where the board wires it in. No herdr, agent, SSH or app."""
from pathlib import Path
import argparse,os,json,hashlib,subprocess,sys,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
# The complete real BoardItem declaration, as run-title-rename-tests.py takes it.
text=(ROOT/'Shepherd/Hosts/Views/AgentBoardView.swift').read_text();start=text.index('enum BoardItem:');end=text.index('/// The sidebar content',start)
board=out/'BoardItem.swift';board.write_text('import SwiftUI\n'+text[start:end])
# The real HerdrClient, built the way run-seen-marking-tests.py builds it, with the naming and the title rename.
sources=['ShepherdKit/Sources/ShepherdKit/Resources.swift','Shepherd/Agents/AgentSessionNaming.swift','Shepherd/Agents/AgentIdleStopPolicy.swift','Shepherd/Hosts/Views/TitleRename.swift',
 'ShepherdKit/Sources/ShepherdKit/Agents/AgentKind.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/HerdrClient.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Transport/HerdrTransport.swift',
 'ShepherdKit/Sources/ShepherdKit/HerdrKit/Terminal/ShellQuoting.swift']+[str(x.relative_to(ROOT)) for x in sorted((ROOT/'ShepherdKit/Sources/ShepherdKit/HerdrKit/Models').glob('*.swift'))]
tests=['Tests/Agents/SessionNamingTests.swift']
pi=['Shepherd/Agents/AgentRuntime/pi-session-name.mjs','Shepherd/Agents/AgentRuntime/pi-host.mjs','Shepherd/Agents/AgentRuntime/pi-control.mjs','Shepherd/Agents/AgentRuntime/pi-entry.ts',
 'Shepherd/Agents/AgentRuntime/runtime.mjs','Tests/AgentBrowser/Phase3/PiIntegrationTests.mjs']
checked=['Shepherd/Hosts/Views/AgentBoardView.swift','Shepherd/Agents/AgentLaunchService.swift','Shepherd/Agents/PiLaunchCoordinator.swift','Shepherd/Agents/PiHostBridge.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sorted(set(sources+tests+pi+checked))},indent=2))
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 j=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and j['naturalExitConfirmed'] and not j['signalsSent'] and j['cleanupVerified'],name
stage('naming-build',120,['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library',*sources,str(board),*tests,'-o',str(out/'naming-tests')])
stage('naming-tests',60,[str(out/'naming-tests')])
stage('pi-naming',60,['node','--test','Tests/AgentBrowser/Phase3/PiIntegrationTests.mjs'])

# Where it is wired in.
def read(n):return (ROOT/n).read_text()
b=read('Shepherd/Hosts/Views/AgentBoardView.swift')
rename=b[b.index('    private func rename('):b.index('    private func nameAgentSession(')]
succeeded=rename[rename.index('succeeded: {'):rename.index('}, failed: {')]
failed=rename[rename.index('}, failed: {'):rename.index('}) { client in')]
assert 'nameAgentSession(after: commit)' in succeeded and 'nameAgentSession' not in failed,'only a rename herdr took is passed on'
assert b.count('nameAgentSession(after: commit)')==1
naming=b[b.index('    private func nameAgentSession('):b.index('    private static func namingConnection(')]
assert 'AgentSessionNaming.rename(after: commit, machineID: machine.id)' in naming and 'AgentSessionNamer.shared.add(rename)' in naming
assert 'AgentLaunchService.shared.namePiSession(rename.name, pane: pane, on: machine)' in naming,'Pi through its launch, never typed'
connection=b[b.index('    private static func namingConnection('):b.index('    /// Counts a read of the herdr')]
assert 'guard machineStore.isCurrentConnection(machine) else { throw MachineStore.EditError.settingsChanged }' in connection and 'makeHerdrTransport(for: try machineStore.currentMachine(matching: machine))' in connection
snapshot=b[b.index('    private func showSnapshot()'):b.index('    /// Points `selection` at the newest snapshot')]
assert 'AgentSessionNamer.shared.observe(agents, machineID: machine.id, herdrMachineID: nil) { [machineStore, machine] in\n            try Self.namingConnection(machineStore, machine)' in snapshot
machines=b[b.index('    private func showHerdrMachines()'):b.index('    /// Takes in the snapshot the monitor has just read')]
assert 'namer.keep(herdrMachineIDs: Set(groups.map(\\.id)), machineID: machine.id)' in machines
assert 'for group in groups where group.error == nil && group.hasLoaded {\n            namer.observe(group.agents, machineID: machine.id, herdrMachineID: group.id) { [machineStore, machine] in\n                try Self.namingConnection(machineStore, machine)' in machines
# The rest of the board stays as it was.
assert b.count('monitor.refreshNow()')==2 and b.count('settleRenameCommit(onHerdrMachine:')==3
launch=read('Shepherd/Agents/AgentLaunchService.swift')
assert 'piLaunches[AgentPaneIdentity(key: BrowserKey(machine: machine, pane: pane), terminalID: pane.terminalID)]?.nameSession(name) == true' in launch
coordinator=read('Shepherd/Agents/PiLaunchCoordinator.swift')
assert '!stopped && failure == nil && host.nameSession(launchID: stage.id, name: name)' in coordinator
bridge=read('Shepherd/Agents/PiHostBridge.swift')
status=bridge[bridge.index('            case "status":'):bridge.index('            default: throw PiBridgeFailure.invalidRequest')]
assert 'registrations[launch.id]?.sessionName' in status,'a status reply carries its own launch\'s name'
entry=read('Shepherd/Agents/AgentRuntime/pi-entry.ts');host=read('Shepherd/Agents/AgentRuntime/pi-host.mjs');runtime=read('Shepherd/Agents/AgentRuntime/runtime.mjs')
assert "const naming = registerPiSessionNaming(pi);" in entry and 'sessionName: naming.offer,' in entry
assert 'if(current.sessionName!==undefined){try{sessionName(current.sessionName);}catch{}}' in host
assert "'pi-mcp-registration.mjs','pi-session-name.mjs','pi-entry.ts'" in runtime,'the version folder hash covers the Pi session naming files'
assert 'pi-herdr.mjs' not in runtime,'the version folder does not bundle the retired app-owned Herdr reporter'
module=read('Shepherd/Agents/AgentRuntime/pi-session-name.mjs')
assert 'pi.setSessionName(name)' in module and 'sendUserMessage' not in module and 'sendMessage' not in module,'Pi is named, never typed into'
# The idle stop before a resume keeps its own rule.
idle=read('Shepherd/Agents/AgentIdleStopPolicy.swift')
assert 'showsOnlySuggestion' not in idle and 'AgentSessionNaming' not in idle
# No new words on screen: nothing is shown while a name waits.
assert 'String(localized' not in read('Shepherd/Agents/AgentSessionNaming.swift') and 'Text(' not in read('Shepherd/Agents/AgentSessionNaming.swift')
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':3,'actualHerdrClient':True,'fakeTransportOnly':True,'fakePiBridge':True,'herdrAgentSSHOrAppTouched':False},indent=2))
print('PASS session naming runner: 3 stages and source checks')
