#!/usr/bin/env python3
"""Keeping the board and the notifications up to date with herdr's events.subscribe: the request, the lines, when a snapshot
is read, the local socket's subscription against a stand-in, MachineMonitor over a fake transport, its herdr machines'
task group built with -O as a release build is, and — when herdr is installed — against a test server of its own. Never
the herdr anyone works in; no app, no SSH."""
from pathlib import Path
import argparse,os,json,hashlib,pwd,re,signal,socket,subprocess,sys,platform,time
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--skip-live',action='store_true')
a=p.parse_args();out=a.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache','socket']:(out/n).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
models=['Shepherd/HerdrKit/Models/HerdrSubscription.swift','Shepherd/HerdrKit/Models/HerdrMessage.swift','Shepherd/HerdrKit/Models/JSONValue.swift']
schedule=['Shepherd/HerdrKit/Live/HerdrRefreshSchedule.swift']
local=models+['Shepherd/HerdrKit/Models/HerdrMachine.swift','Shepherd/HerdrKit/Transport/HerdrTransport.swift','Shepherd/HerdrKit/Transport/LocalHerdrTransport.swift',
 'Shepherd/HerdrKit/Transport/ConnectionFailureDescription.swift','Shepherd/HerdrKit/Terminal/HerdrExecutable.swift','Shepherd/HerdrKit/Terminal/LocalCommand.swift','Shepherd/HerdrKit/Terminal/ShellQuoting.swift']
# The real HerdrClient, built the way run-seen-marking-tests.py builds it, and the monitor.
client=['Shepherd/Agents/AgentRuntime.swift','Shepherd/Agents/AgentSavedSession.swift','Shepherd/Agents/AgentIdleStopPolicy.swift','Shepherd/Agents/AgentLaunchState.swift',
 'Shepherd/HerdrKit/HerdrClient.swift','Shepherd/HerdrKit/Transport/HerdrTransport.swift','Shepherd/HerdrKit/Terminal/ShellQuoting.swift']+[str(x.relative_to(ROOT)) for x in sorted((ROOT/'Shepherd/HerdrKit/Models').glob('*.swift'))]
monitor=client+schedule+['Shepherd/Hosts/Monitoring/MachineMonitor.swift','Shepherd/HerdrKit/Transport/ConnectionFailureDescription.swift']
live=monitor+['Shepherd/HerdrKit/Transport/LocalHerdrTransport.swift','Shepherd/HerdrKit/Terminal/HerdrExecutable.swift','Shepherd/HerdrKit/Terminal/LocalCommand.swift']
tests=['Tests/Agents/LiveUpdateModelTests.swift','Tests/Agents/LocalSubscribeTests.swift','Tests/Agents/MachineMonitorTests.swift','Tests/Agents/FakeHerdr.swift',
 'Tests/Agents/OptimizedSnapshotTests.swift','Tests/Agents/LiveHerdrSubscribeTests.swift']
checked=['Shepherd/Hosts/Views/AgentBoardView.swift','Shepherd/Hosts/Monitoring/MachineMonitors.swift','Shepherd/HerdrKit/Transport/SSHHerdrTransport.swift',
 'Shepherd/Notifications/NotificationCoordinator.swift','Shepherd/Notifications/NotificationFeed.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sorted(set(models+schedule+local+monitor+live+tests+checked))},indent=2))
def stage(name,seconds,args,extraEnv=()):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),
  *[f'--env={e}' for e in extraEnv],'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 j=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and j['naturalExitConfirmed'] and not j['signalsSent'] and j['cleanupVerified'],name
flags=['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library']
stage('model-build',90,flags+models+schedule+['Tests/Agents/LiveUpdateModelTests.swift','-o',str(out/'model-tests')])
stage('model-tests',20,[str(out/'model-tests')])
stage('local-subscribe-build',90,flags+local+['Tests/Agents/LocalSubscribeTests.swift','-o',str(out/'local-subscribe-tests')])
stage('local-subscribe-tests',60,[str(out/'local-subscribe-tests'),str(out/'socket')])
stage('monitor-build',120,flags+monitor+['Tests/Agents/MachineMonitorTests.swift','Tests/Agents/FakeHerdr.swift','-o',str(out/'monitor-tests')])
stage('monitor-tests',120,[str(out/'monitor-tests')])
# The herdr machines' task group the way a release build has it (-O, whole module), run with
# MallocScribble=1: Swift 6.3/6.4 -O drops `index` from `return (index, try await …, nil)` in a do
# with a catch returning a tuple too (swiftlang/swift#92698, SHPHRD-54), which -Onone never shows.
# A trap there, with no FAIL line, is a result landing out of bounds.
stage('optimized-snapshot-build',180,flags+['-O','-wmo']+monitor+['Tests/Agents/FakeHerdr.swift','Tests/Agents/OptimizedSnapshotTests.swift','-o',str(out/'optimized-snapshot-tests')])
stage('optimized-snapshot-tests',60,[str(out/'optimized-snapshot-tests')],extraEnv=['MallocScribble=1'])
stages=8

# Optional: a herdr test server of its own — home, config, state and
# sockets under the output directory (the sockets by relative path, an
# absolute one there being too long for a Unix socket address), started
# with an environment of its own and stopped here.
herdr=os.environ.get('SHEPHERD_TEST_HERDR') or str(Path(pwd.getpwuid(os.getuid()).pw_dir)/'.local/bin/herdr')
liveRun='skipped'
if not a.skip_live and os.access(herdr,os.X_OK):
 d=out/'herdr';home=d/'home';(home/'.config'/'herdr').mkdir(parents=True);(home/'.state').mkdir()
 (home/'.config'/'herdr'/'config.toml').write_text('onboarding = false\n\n[update]\nversion_check = false\nmanifest_check = false\n')
 serverEnv={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(home),'XDG_CONFIG_HOME':str(home/'.config'),'XDG_STATE_HOME':str(home/'.state'),
  'HERDR_SOCKET_PATH':'t.sock','SHELL':'/bin/sh','TERM':'xterm-256color','LANG':'en_US.UTF-8'}
 def request(method,params):
  here=os.getcwd();os.chdir(d)
  try:
   s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(5);s.connect('t.sock')
   s.sendall((json.dumps({'id':method,'method':method,'params':params})+'\n').encode());buf=b''
   while b'\n' not in buf:
    c=s.recv(1<<16)
    if not c:break
    buf+=c
   s.close();return json.loads(buf.split(b'\n',1)[0]) if buf else None
  finally:os.chdir(here)
 version=subprocess.run([herdr,'--version'],capture_output=True,text=True,env=serverEnv,cwd=d,timeout=20).stdout.strip()
 server=subprocess.Popen([herdr,'server'],cwd=d,env=serverEnv,stdout=(d/'server.out').open('w'),stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,start_new_session=True)
 try:
  for _ in range(100):
   try:
    if (d/'t.sock').exists() and request('ping',{}):break
   except OSError:pass
   time.sleep(0.1)
  else:raise RuntimeError('the test herdr server did not come up')
  stage('live-build',120,flags+live+['Tests/Agents/LiveHerdrSubscribeTests.swift','-o',str(out/'live-tests')])
  stage('live-tests',60,[str(out/'live-tests'),str(d)])
  stages+=2;liveRun=version
 finally:
  try:request('server.stop',{})
  except OSError:pass
  for _ in range(50):
   if server.poll() is not None:break
   time.sleep(0.1)
  for sig in [signal.SIGTERM,signal.SIGKILL]:
   if server.poll() is None:
    try:os.killpg(server.pid,sig)
    except ProcessLookupError:pass
    time.sleep(1)
  assert server.poll() is not None,'the test herdr server is still running'

# Where it is wired in.
def read(n):return (ROOT/n).read_text()
board=read('Shepherd/Hosts/Views/AgentBoardView.swift')
for gone in ['keepUpToDate','keepHerdrMachinesUpToDate','waitForAnyPaneChange','fetchSnapshots','isPermanentFailure(','ConnectionRun','retryCount','refreshCount',
             'withTaskGroup','withThrowingTaskGroup','client.snapshot(','events.wait','NotificationFeed','coverWithBoard','@State private var agents']:
 assert gone not in board,('the board keeps no connection of its own',gone)
assert '.task(id: machine.connectionIdentity) {\n            await MachineMonitors.shared.holdForBoard(machine, in: machineStore)' in board
assert board.count('monitor.refreshNow()')==2 and 'monitor.retry()' in board
assert '.onChange(of: monitor.snapshotCount, initial: true)' in board and '.onChange(of: monitor.herdrMachineRoundCount, initial: true)' in board
assert not (ROOT/'Shepherd/Notifications/MachineWatcher.swift').exists()
swift={str(x.relative_to(ROOT)):x.read_text() for x in (ROOT/'Shepherd').rglob('*.swift')}
assert not [n for n,t in swift.items() if 'MachineWatcher' in t]
# The comments that had herdr.sock unable to subscribe, and the rest the design found wrong.
for wrong in ['ack never arrives','ack never even arrives','acknowledgement never arrives before','AgentBoardView polls','`min_revision`','struct HerdrEvent',
              'once the Citadel/swift-nio-ssh package dependency is wired up',"while the real SSH transport isn't buildable yet"]:
 hits=[n for n,t in swift.items() if wrong in t]
 assert not hits,(wrong,hits)
# events() left the protocol; the transports don't keep it (fakes elsewhere may).
assert not [n for n,t in swift.items() if n.startswith('Shepherd/HerdrKit/') and 'func events()' in t]
transport=read('Shepherd/HerdrKit/Transport/LocalHerdrTransport.swift')
assert 'answers an ordinary request on a connection and then closes it' in transport and '`events.subscribe`,\n/// `events.wait` and `agent.wait`' in transport
assert 'a monitor polling that way' in transport and 'FD_CLOEXEC' in transport
ssh=read('Shepherd/HerdrKit/Transport/SSHHerdrTransport.swift')
assert 'func subscribe(params: JSONValue) async throws -> HerdrSubscriptionLines' in ssh and 'ByteStreamBridge(continuation: inboundContinuation)' in ssh
# Swift 6.3/6.4 -O drops `index` from `return (index, try await …, nil)` in a do with a catch
# returning a tuple too (swiftlang/swift#92698, SHPHRD-54): nowhere, and the herdr machines'
# task group takes the snapshot into a constant first.
code=lambda t:'\n'.join(l for l in t.splitlines() if not l.lstrip().startswith('//'))
assert not [n for n,t in swift.items() if re.search(r'return \(\w+, try await',code(t))]
monitorSource=read('Shepherd/Hosts/Monitoring/MachineMonitor.swift')
assert 'let snapshot = try await client.snapshot(on: machine)\n                        return (index, snapshot, nil)' in monitorSource and 'swiftlang/swift#92698' in monitorSource and 'SHPHRD-54' in monitorSource
assert 'acknowledgementTimeout: Duration = .seconds(5)' in monitorSource and 'snapshotTimeout: Duration = .seconds(15)' in monitorSource
assert 'herdrMachineInterval: Duration = .seconds(5)' in monitorSource and 'stopDelay: Duration = .seconds(1)' in monitorSource
sched=read('Shepherd/HerdrKit/Live/HerdrRefreshSchedule.swift')
assert 'gather: Duration = .milliseconds(100)' in sched and 'minimumInterval: Duration = .milliseconds(500)' in sched and 'idleRefresh: Duration = .seconds(25)' in sched
assert re.findall(r'^import (\w+)',sched,re.M)==['Foundation'] and re.findall(r'^import (\w+)',read(models[0]),re.M)==['Foundation']
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':stages,'liveHerdrTestServer':liveRun,'actualHerdrClient':True,'usersHerdrTouched':False,'appRun':False,'ssh':False},indent=2))
print(f'PASS live update runner: {stages} stages, live test server: {liveRun}')
