#!/usr/bin/env python3
"""Agent events: the JSON contract and its examples, and the deriver; no app or herdr."""
from pathlib import Path
import argparse,os,json,hashlib,re,subprocess,sys,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
EXAMPLES=ROOT/'Tests/Notifications/agent-events'
events=[str(p.relative_to(ROOT)) for p in sorted((ROOT/'Shepherd/HerdrKit/Events').glob('*.swift'))]
# The production pane, tab and workspace models the deriver reads snapshots through.
models=['Shepherd/HerdrKit/Models/AgentModels.swift','Shepherd/HerdrKit/Models/TabModels.swift','Shepherd/HerdrKit/Models/AgentTitleDisplay.swift','Shepherd/HerdrKit/Models/AgentLaunchModels.swift','Shepherd/HerdrKit/Models/HerdrMachine.swift','Shepherd/HerdrKit/Models/JSONValue.swift']
event_tests=events+models+['Tests/Notifications/AgentEventTests.swift']
examples=sorted(str(p.relative_to(ROOT)) for p in EXAMPLES.glob('*.json'))
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sorted(set(event_tests+examples))},indent=2))
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 j=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and j['naturalExitConfirmed'] and not j['signalsSent'] and j['cleanupVerified'],name
flags=['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library']
stage('event-build',120,flags+event_tests+['-o',str(out/'event-tests')])
stage('event-tests',60,[str(out/'event-tests'),str(EXAMPLES)])

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

# The event types need Foundation alone.
for n in events:
 assert re.findall(r'^import (\w+)',(ROOT/n).read_text(),re.M)==['Foundation'],n
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':2,'exampleJSONIsTheReference':True,'idsCheckedInPython':True,'appOrHerdrTouched':False},indent=2))
print(f'PASS agent event runner: 2 stages, {len(canonical)} canonical examples checked in Python')
