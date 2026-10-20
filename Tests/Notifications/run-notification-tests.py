#!/usr/bin/env python3
"""Agent notifications: the event JSON contract and its examples, the deriver, the policy and text; no app, herdr or notification."""
from pathlib import Path
import argparse,os,json,hashlib,re,subprocess,sys,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
EXAMPLES=ROOT/'Tests/Notifications/agent-events'
events=[str(p.relative_to(ROOT)) for p in sorted((ROOT/'ShepherdKit/Sources/ShepherdKit/HerdrKit/Events').glob('*.swift'))]
# The production pane, tab and workspace models the deriver reads snapshots through.
models=['ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentModels.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/TabModels.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentTitleDisplay.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentLaunchModels.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/HerdrMachine.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/JSONValue.swift']
event_tests=events+models+['Tests/Notifications/AgentEventTests.swift']
policy_tests=['ShepherdKit/Sources/ShepherdKit/HerdrKit/Events/AgentEvent.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Events/AgentEventDigest.swift','ShepherdKit/Sources/ShepherdKit/Notifications/NotificationPolicy.swift','ShepherdKit/Sources/ShepherdKit/Notifications/NotificationText.swift','Tests/Notifications/NotificationPolicyTests.swift']
app=[str(p.relative_to(ROOT)) for p in sorted((ROOT/'Shepherd/Notifications').glob('*.swift'))]+[str(p.relative_to(ROOT)) for p in sorted((ROOT/'ShepherdKit/Sources/ShepherdKit/Notifications').glob('*.swift'))]+['ShepherdKit/Sources/ShepherdKit/Machines/MachineMonitor.swift','ShepherdKit/Sources/ShepherdKit/Machines/MachineMonitors.swift','Shepherd/Hosts/Views/NotificationSettingsView.swift','Shepherd/Hosts/Views/MachinesSettingsView.swift','Shepherd/Hosts/Views/AgentBoardView.swift','Shepherd/ContentView.swift','Shepherd/Shepherd.swift','Shepherd/Localizable.xcstrings']
examples=sorted(str(p.relative_to(ROOT)) for p in EXAMPLES.glob('*.json'))
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sorted(set(event_tests+policy_tests+app+examples))},indent=2))
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 j=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and j['naturalExitConfirmed'] and not j['signalsSent'] and j['cleanupVerified'],name
flags=['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library']
stage('event-build',120,flags+event_tests+['-o',str(out/'event-tests')])
stage('event-tests',60,[str(out/'event-tests'),str(EXAMPLES)])
stage('policy-build',90,flags+policy_tests+['-o',str(out/'policy-tests')])
stage('policy-tests',20,[str(out/'policy-tests'),str(EXAMPLES)])

# The contract, checked by an implementation that isn't Swift: ids and
# collapse keys are the SHA-256 the contract spells out, sizes in bounds.
h=lambda s:hashlib.sha256(s.encode()).hexdigest()[:32]
canonical=['needs-input.json','resumed.json','finished.json']
for name in canonical:
 e=json.loads((EXAMPLES/name).read_text());s=e['subject'];i=s['herdr']['instance_id']
 assert e['id']==h(f"{i}\n{s['terminal_id']}\n{e['transition']['state_change_seq']}\n{e['kind']}"),name
 assert s['collapse_key']==h(f"{i}\n{s['terminal_id']}") and len(s['collapse_key'].encode())<=64,name
 assert len(json.dumps(e,separators=(',',':'),ensure_ascii=False).encode())<=2048,name
 assert re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ',e['observed_at']),name
 def keys_of(v):
  return [k for k,x in v.items() for k in [k]+keys_of(x)] if isinstance(v,dict) else []
 assert all(re.fullmatch(r'[a-z]+(_[a-z]+)*',k) for k in keys_of(e)) and not {'cwd','working_directory','output','text'}&set(keys_of(e)),name
assert len({json.loads((EXAMPLES/n).read_text())['subject']['collapse_key'] for n in canonical})==1

# Only the presenter talks to UserNotifications; the event types need Foundation alone.
importers=[str(p.relative_to(ROOT)) for p in (ROOT/'Shepherd').rglob('*.swift') if re.search(r'^import UserNotifications',p.read_text(),re.M)]
assert importers==['Shepherd/Notifications/UserNotificationPresenter.swift'],importers
for n in events:
 assert re.findall(r'^import (\w+)',(ROOT/n).read_text(),re.M)==['Foundation'],n

# Where it is wired in: each machine's monitor feeds its snapshots, its herdr
# machines' included, over the one connection the board shares while it shows
# the machine; the notifications keep every machine's monitor running; the
# window says what is viewed and goes to a clicked pane.
board=(ROOT/'Shepherd/Hosts/Views/AgentBoardView.swift').read_text()
assert 'NotificationFeed' not in board and 'coverWithBoard' not in board
assert '.task(id: machine.connectionIdentity) {\n            await MachineMonitors.shared.holdForBoard(machine, in: machineStore)' in board
monitors=(ROOT/'ShepherdKit/Sources/ShepherdKit/Machines/MachineMonitors.swift').read_text()
shep=(ROOT/'Shepherd/Shepherd.swift').read_text()
assert 'listener: makeListener?(machine)' in monitors and 'MachineMonitors.shared.makeListener = { NotificationFeed(machine: $0) }' in shep and 'pollInterval: machine.isLocal ? .seconds(3) : .seconds(5)' in monitors and 'pinHostKeyFingerprint' in monitors
monitor=(ROOT/'ShepherdKit/Sources/ShepherdKit/Machines/MachineMonitor.swift').read_text()
assert monitor.count('listener?.connected(client)')==1 and monitor.count('listener?.observe(')==2 and 'for group in groups where group.error == nil && group.hasLoaded {\n            listener?.observe(' in monitor
assert 'if isPermanent(failure) {\n                isStoppedOnFailure = true' in monitor and 'pinHostKey(newFingerprint)' in monitor
feed=(ROOT/'Shepherd/Notifications/NotificationFeed.swift').read_text()
assert 'final class NotificationFeed: MachineMonitorListener {' in feed
content=(ROOT/'Shepherd/ContentView.swift').read_text()
assert 'controlActiveState == .key' in content and 'setViewedPanes(panes)' in content and 'setViewedPanes([])' in content
assert '.onChange(of: NotificationCoordinator.shared.navigationRequest, initial: true)' in content and '.onChange(of: paneDestinations)' in content
assert shep.index('NotificationCoordinator.shared.prepare()')<shep.index('guard ShepherdBrowserFeature.shared.isEnabled else { return }')<shep.index('func applicationDidFinishLaunching')<shep.index('NotificationCoordinator.shared.start()')
assert 'Window(Text(verbatim: "hrdrhrdrhrdr"), id: "main")' in shep and 'WindowGroup {' not in shep
assert not (ROOT/'Shepherd/Notifications/MachineWatcher.swift').exists()
coordinator=(ROOT/'Shepherd/Notifications/NotificationCoordinator.swift').read_text()
assert 'confirmationDelay: Duration = .milliseconds(1500)' in coordinator and 'SHEPHERD_OWNED_OPERATOR_ROOT' in coordinator
assert 'MachineMonitors.shared.watch(isWatching ? machines : [], in: machineStore)' in coordinator and 'boardCoverage' not in coordinator and 'watcher' not in coordinator

# Settings: its own page, ⓘ buttons as elsewhere, every string in Korean and Japanese.
page=(ROOT/'Shepherd/Hosts/Views/NotificationSettingsView.swift').read_text()
settings=(ROOT/'Shepherd/Hosts/Views/MachinesSettingsView.swift').read_text()
assert page.count('InfoButton(accessibilityLabel: "About ')==3 and 'systemName: "info.circle"' not in page
assert 'NotificationSettingsView {' in settings and 'accessibilityIdentifier("settings.notifications")' in settings
text=(ROOT/'ShepherdKit/Sources/ShepherdKit/Notifications/NotificationText.swift').read_text()
literal=r'"((?:[^"\\]|\\.)*)"'
keys=set()
for source,pattern in [(page,r'(?:Text|Toggle|Label|Button|LabeledContent|accessibilityLabel:|explanation:|\.help)\(?\s*'+literal),(text,r'String\(localized: '+literal)]:
 for raw in re.findall(pattern,source):
  keys.add(re.sub(r'\\\([^)]*\)','%@',raw).replace('\\"','"'))
keys-={'chevron.left','checkmark.circle.fill'}
strings={**json.loads((ROOT/'Shepherd/Localizable.xcstrings').read_text())['strings'],**json.loads((ROOT/'ShepherdKit/Sources/ShepherdKit/Resources/Localizable.xcstrings').read_text())['strings']}
missing=[k for k in sorted(keys) if not all(strings.get(k,{}).get('localizations',{}).get(l,{}).get('stringUnit',{}).get('state')=='translated' for l in ['ko','ja'])]
assert len(keys)>=20 and not missing,missing
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':4,'exampleJSONIsTheReference':True,'idsCheckedInPython':True,'localizedKeys':len(keys),'appHerdrOrNotificationTouched':False},indent=2))
print(f'PASS notification runner: 4 stages, {len(canonical)} canonical examples checked in Python, {len(keys)} strings in ko and ja')
