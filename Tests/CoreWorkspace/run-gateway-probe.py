#!/usr/bin/env python3
"""Owned official-core routing discovery, NOT product gateway qualification.
Three private cores, no SSH/provider/account or global core configuration.
"""
from pathlib import Path
import argparse, ctypes, errno, hashlib, json, os, re, selectors, shlex, subprocess, sys, time
ROOT=Path(__file__).resolve().parents[2]

def environment(out, name):
 home=out/name
 return {'PATH':str(out/'bin')+':/usr/bin:/bin','HOME':str(home),'XDG_CONFIG_HOME':str(home/'config'),
 'XDG_STATE_HOME':str(home/'state'),'XDG_RUNTIME_DIR':str(home/'runtime'),'HC_SOCKET':str(home/'c.sock'),
 'HC_SESSION':'owned','SSH_CONNECTION':'owned-fixture-no-launchd','DO_NOT_TRACK':'1','LANG':'en_US.UTF-8'}

class RPC:
 def __init__(self,binary,out,name):
  self.env=environment(out,name);self.pending=b'';self.id=0
  self.error=(out/(name+'-connect.stderr')).open('wb')
  self.p=subprocess.Popen([str(binary),'connect'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.error,
                          env=self.env,cwd=out/name,bufsize=0)
  try:
   self.hello=self.call('hello',{'generation':1,'framed':False})
   assert self.hello['version']=='0.1.17' and self.hello['generation']==1
  except BaseException:
   self.close();raise
 def call(self,method,params=None,timeout=10):
  self.id+=1;wanted=self.id
  self.p.stdin.write(json.dumps({'jsonrpc':'2.0','id':wanted,'method':method,'params':params or {}}).encode()+b'\n')
  end=time.monotonic()+timeout
  with selectors.DefaultSelector() as selector:
   selector.register(self.p.stdout,selectors.EVENT_READ)
   while b'\n' not in self.pending:
    left=end-time.monotonic()
    if left<=0 or not selector.select(left):raise TimeoutError(method)
    data=os.read(self.p.stdout.fileno(),65536)
    if not data:raise RuntimeError('connection closed: '+method)
    self.pending+=data
    if len(self.pending)>2<<20:raise RuntimeError('oversized reply')
  line,self.pending=self.pending.split(b'\n',1);reply=json.loads(line)
  assert reply.get('id')==wanted,'unexpected RPC identity'
  if 'error' in reply:raise RuntimeError(json.dumps(reply['error']))
  return reply['result']
 def close(self):
  if self.p.stdin:self.p.stdin.close()
  try:self.p.wait(timeout=3)
  except subprocess.TimeoutExpired:self.p.kill();self.p.wait();raise RuntimeError('owned connect child needed forced cleanup')
  self.error.close()

def worker(out,binary,document_sdk=None):
 clients=[];terminal_ids=[];known=set();failure=None;observations={}
 def save():
  (out/'report.json').write_text(json.dumps({'probeOnly':True,'productQualified':False,'observations':observations,
    'ownedPIDs':sorted(known),'failure':failure,'ownedProcessesExited':False},indent=2))
 def remember_descendants():
  for client in clients:
   status=client.call('server.status',timeout=3)
   known.update(h['pid'] for h in status.get('holders',[]))
  # ps is a set-id executable and cannot run in this seatbelt. Query only
  # known owned parents through the public, unprivileged libproc API instead;
  # do not relax sandbox policy or inspect another process's argv/environment.
  lib=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
  lib.proc_listchildpids.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_int]
  lib.proc_listchildpids.restype=ctypes.c_int
  def children(pid):
   buf=(ctypes.c_int*4096)();ctypes.set_errno(0)
   n=lib.proc_listchildpids(pid,buf,ctypes.sizeof(buf));error=ctypes.get_errno()
   if n<0 or (n==0 and error not in [0,errno.ESRCH]):raise RuntimeError('owned child inspection denied: '+str(error))
   result={p for p in buf if p>0}
   if len(result)>=4096:raise RuntimeError('owned child inspection capacity exceeded')
   return result
  assert {c.p.pid for c in clients} <= children(os.getpid()),'owned-child inspection canary failed'
  for _ in range(8):
   fresh=set().union(*(children(parent) for parent in known)) if known else set()
   if fresh<=known:break
   known.update(fresh)
  else:raise RuntimeError('owned process hierarchy too deep')
  save()
 try:
  for name in ['h','r','q']:
   client=RPC(binary,out,name);clients.append(client);known.add(client.p.pid)
   status=client.call('server.status');known.add(status['pid']);save()
  hub,remote,other=clients
  assert len({c.hello['core']['id'] for c in clients})==3
  def via(name):
   path=out/('via-'+name+'.sh')
   env=environment(out,name)
   path.write_text('#!/bin/sh\nset -eu\nexec /usr/bin/env -i '+ ' '.join(shlex.quote(k+'='+v) for k,v in env.items())+' /bin/sh -c "$1"\n')
   path.chmod(0o700);return shlex.quote(str(path))
  a=hub.call('machine.add',{'via':via('r'),'name':'owned-before','session':'owned'})
  origin=a['id'];assert origin==remote.hello['core']['id']
  observations['remoteCoreID']=origin
  name='shepherd-gateway-probe'
  hub.call('doc.set',{'on':origin,'name':name,'version':0,'value':{'owned':'remote'}})
  direct=remote.call('doc.get',{'name':name});local=hub.call('doc.get',{'name':name})
  assert direct['value']=={'owned':'remote'} and direct['version']==1 and local['value'] is None
  observations['stableIDDocRouting']=True
  def run(client,on=None):
   params={'argv':['/usr/bin/python3','-I','-S','-B','-c','import time;print("OWNED-GATEWAY",flush=True);time.sleep(30)'],
           'cwd':str(out),'keep':False}
   if on:params['on']=on
   record=client.call('terminal.run',params);suffix=record['address'].rsplit('/',1)[-1]
   assert re.fullmatch(r't[0-9a-z]+',suffix)
   return record,suffix
  rt,tid=run(hub,origin);terminal_ids.append((remote,tid));known.add(rt['pid']);save()
  lt,lid=run(hub);terminal_ids.append((hub,lid));known.add(lt['pid']);save()
  assert remote.call('terminal.get',{'terminal':tid})['pid']==rt['pid']
  stable_address=origin+'/'+tid
  assert hub.call('terminal.get',{'terminal':stable_address})['pid']==rt['pid']
  listed=hub.call('terminal.list',{'on':origin,'all':True})
  observations['listWithOnAddresses']=[r['address'] for r in listed['terminals']]
  observations['listWithOnIncludesLocal']=any('/' not in r['address'] for r in listed['terminals'])
  observations['listMachines']=listed.get('machines',[])
  hub.call('machine.rename',{'machine':'owned-before','new_name':'owned-after'})
  assert hub.call('doc.get',{'on':origin,'name':name})['value']=={'owned':'remote'}
  assert hub.call('terminal.get',{'terminal':stable_address})['pid']==rt['pid']
  b=hub.call('machine.add',{'via':via('q'),'name':'owned-before','session':'owned'})
  assert b['id']==other.hello['core']['id'] and b['id']!=origin
  qt,qid=run(other);terminal_ids.append((other,qid));known.add(qt['pid']);save()
  # Reusing a display alias must not retarget a stable origin selector.
  assert hub.call('doc.get',{'on':'owned-before','name':name})['value'] is None
  assert hub.call('doc.get',{'on':origin,'name':name})['value']=={'owned':'remote'}
  assert hub.call('terminal.get',{'terminal':stable_address})['pid']==rt['pid']
  observations['renameAndAliasReuseDoNotRetargetStableID']=True
  # Discover whether the core's id-or-name namespace is actually unambiguous.
  # This reads only the private probe document; no mutation is sent on the
  # potentially shadowed selector.
  hub.call('machine.rename',{'machine':'owned-after','new_name':b['id']})
  try:
   shadowed=hub.call('doc.get',{'on':b['id'],'name':name})
   observations['coreIDAliasCanShadowAnotherCore']=shadowed['value']=={'owned':'remote'}
  finally:hub.call('machine.rename',{'machine':b['id'],'new_name':'owned-after'})
  if document_sdk:
   with (out/'document-sdk.log').open('wb') as log:
    result=subprocess.run([str(document_sdk),str(binary),str(out),str(out/'document-sdk.json')],env=environment(out,'h'),stdout=log,stderr=subprocess.STDOUT,timeout=45)
   assert result.returncode==0,'production gateway document SDK failed'
   sdk=json.loads((out/'document-sdk.json').read_text());assert sdk['passed']
   known.update(sdk['ownedPIDs']);observations['productionDocumentSDK']=sdk;save()
  remember_descendants()
  hub.call('machine.rm',{'machine':'owned-before'});hub.call('machine.rm',{'machine':'owned-after'})
  observations['onlyPrivateCoresMutated']=True
 except BaseException as error:failure=type(error).__name__+': '+str(error)
 finally:
  try:remember_descendants()
  except BaseException as error:failure=failure or 'process inspection: '+str(error)
  for client,terminal in terminal_ids:
   try:client.call('terminal.kill',{'terminal':terminal},timeout=5)
   except BaseException as error:failure=failure or 'terminal cleanup: '+str(error)
  for client in clients:
   try:client.call('server.stop',timeout=5)
   except BaseException as error:failure=failure or 'core cleanup: '+str(error)
  for client in clients:
   try:client.close()
   except BaseException as error:failure=failure or str(error)
  save()
  end=time.monotonic()+5
  while True:
   alive=[]
   for pid in known:
    try:os.kill(pid,0);alive.append(pid)
    except ProcessLookupError:pass
   if not alive:break
   if time.monotonic()>end:failure=failure or 'owned PID retirement unconfirmed: '+str(alive);break
   time.sleep(.025)
  sockets=[str(out/n/'c.sock') for n in ['h','r','q'] if (out/n/'c.sock').exists()]
  if sockets:failure=failure or 'socket retirement unconfirmed'
  report=json.loads((out/'report.json').read_text());report.update(failure=failure,ownedProcessesExited=not alive,socketsRemoved=not sockets)
  (out/'report.json').write_text(json.dumps(report,indent=2))
 if failure:raise RuntimeError(failure)
 print('INFO owned routing observations complete; not product qualification:',out,flush=True)

if len(sys.argv)>1 and sys.argv[1]=='--worker':
 worker(Path(sys.argv[2]),Path(sys.argv[3]),Path(sys.argv[4]) if len(sys.argv)>4 else None);raise SystemExit(0)

p=argparse.ArgumentParser();p.add_argument('--official-017-archive',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--document-sdk-executable',type=Path);a=p.parse_args()
sys.path.insert(0,str(ROOT/'Tests/CoreProtocol'))
import core_test_artifact as artifacts
out=a.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['bin','home','tmp','h','r','q']:(out/name).mkdir(mode=0o700)
for name in ['h','r','q']:assert len(str(out/name/'c.sock').encode())<104
binary=out/'bin/herdr-core'
provenance=artifacts.extract(artifacts.select(official_017_archive=a.official_017_archive),binary)
(out/'provenance.json').write_text(json.dumps(provenance,indent=2))
profile=out/'private-unix.sb';profile.write_text('(version 1)\n(allow default)\n(deny network*)\n(allow network* (subpath '+json.dumps(str(out))+'))\n')
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(out/'home'),'CFFIXED_USER_HOME':str(out/'home'),'TMPDIR':str(out/'tmp')}
source_hash=hashlib.sha256(Path(__file__).read_bytes()).hexdigest();(out/'source-hashes.json').write_text(json.dumps({str(Path(__file__).relative_to(ROOT)):source_hash}))
try:
 result=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout','90','--natural-exit-grace','10','--log',str(out/'probe.log'),'--','/usr/bin/sandbox-exec','-f',str(profile),sys.executable,'-I','-S',str(Path(__file__).resolve()),'--worker',str(out),str(binary)]+([str(a.document_sdk_executable.resolve())] if a.document_sdk_executable else []),cwd=ROOT,env=env,timeout=130)
finally:
 # A failed worker still gets an owned-scope stop; never the installed daemon.
 for name in ['h','r','q']:
  if (out/name/'c.sock').exists():subprocess.run(['/usr/bin/sandbox-exec','-f',str(profile),str(binary),'server','stop'],env=environment(out,name),capture_output=True,timeout=8)
record=json.loads((out/'probe.stage.json').read_text())
assert result.returncode==0 and record['naturalExitConfirmed'] and not record['signalsSent'] and record['cleanupVerified'],'probe/owned cleanup failed'
assert source_hash==hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'probe source changed'
print((out/'report.json').read_text())
