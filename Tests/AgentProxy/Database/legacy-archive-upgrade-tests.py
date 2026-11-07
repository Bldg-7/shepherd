#!/usr/bin/env python3
"""Actual retained v1 recorder -> current recorder on an owned private archive.
No provider/SSH/user state. Caller must run under a network-denying sandbox.
"""
import argparse, errno, hashlib, json, os, select, socket, sqlite3, struct, time
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('--baseline',type=Path,required=True)
p.add_argument('--candidate',type=Path,required=True)
p.add_argument('--work',type=Path,required=True)
a=p.parse_args();a.work.mkdir(mode=0o700,parents=True,exist_ok=False)
state=a.work/'state';state.mkdir(mode=0o700)
for operation in ['bind','connect']:
    with socket.socket(socket.AF_INET,socket.SOCK_STREAM) as canary:
        try:
            if operation=='bind':canary.bind(('127.0.0.1',0))
            else:canary.connect(('127.0.0.1',9))
        except OSError as failure:assert failure.errno in [errno.EPERM,errno.EACCES],'network canary was not policy-denied'
        else:raise AssertionError('IP '+operation+' must be sandbox-denied')
identity={'kind':'claude','session':'archive-scope-é','paneID':'pane','terminalID':'terminal','cliVersion':'2.1.309'}
class Recorder:
    def __init__(self,binary,label):
        self.path=state/'ac.sock';self.parent,child=socket.socketpair();self.code=None
        log=os.open(a.work/(label+'.log'),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        actions=[(os.POSIX_SPAWN_DUP2,child.fileno(),3),(os.POSIX_SPAWN_DUP2,log,1),(os.POSIX_SPAWN_DUP2,log,2)]
        if child.fileno()!=3:actions.append((os.POSIX_SPAWN_CLOSE,child.fileno()))
        try:self.pid=os.posix_spawn(str(binary.resolve()),[str(binary.resolve()),'recorder','--socket',str(self.path),'--state-dir',str(state)],{'HOME':str(a.work),'CFFIXED_USER_HOME':str(a.work),'PATH':'/usr/bin:/bin'},file_actions=actions)
        finally:child.close();os.close(log)
        self.parent.settimeout(5)
    def frame(self,kind,payload=None):
        raw=b'' if payload is None else json.dumps(payload,ensure_ascii=False).encode()
        self.parent.sendall(struct.pack('>IBQ',9+len(raw),kind,0 if kind==7 else 1)+raw)
    def query(self,method,**params):
        until=time.monotonic()+5
        while True:
            s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(3)
            try:s.connect(str(self.path));break
            except (FileNotFoundError,ConnectionRefusedError):
                s.close();assert time.monotonic()<until,'owned recorder bind deadline';select.select([self.parent],[],[],.02)
        with s:
            s.sendall(json.dumps({'id':'q','method':method,'params':params}).encode()+b'\n');data=b''
            while b'\n' not in data:
                chunk=s.recv(65536);assert chunk and len(data)<2<<20,'bounded recorder reply';data+=chunk
            result=json.loads(data.split(b'\n')[0]);assert 'result' in result,result
            return result['result']
    def authority(self):
        self.frame(7,{'generation':1,'routes':[{'routeID':'route','identity':identity}]})
        data=b''
        while len(data)<13:
            part=self.parent.recv(13-len(data));assert part,'authority EOF';data+=part
        assert struct.unpack('>IBQ',data)==(9,8,1),'exact authority acknowledgement'
    def begin(self,messages):
        self.frame(1,{'routeID':'route','routeIdentity':identity,'upstream':'anthropic','method':'POST','path':'/v1/messages','headers':[['content-type','application/json'],['x-claude-code-request-class','main'],['x-claude-code-session-id','native-한글-é'],['x-claude-code-agent-id','root']]})
        self.frame(2,{'messages':messages});self.frame(3)
        until=time.monotonic()+5
        while not self.query('conversations.list')['conversations']:
            assert time.monotonic()<until,'MAIN admission deadline'
        self.frame(4,{'status':200,'headers':[['content-type','text/event-stream']]})
    def finish(self,text):
        for event in [{'type':'message_start','message':{'id':'m','role':'assistant','content':[]}},{'type':'content_block_start','index':0,'content_block':{'type':'text','text':text}},{'type':'content_block_stop','index':0},{'type':'message_stop'}]:
            raw=b'data: '+json.dumps(event).encode()+b'\n\n';self.parent.sendall(struct.pack('>IBQ',9+len(raw),5,1)+raw)
        self.frame(6,{'outcome':'complete'})
    def stop(self):
        if self.code is not None:return self.code
        self.parent.shutdown(socket.SHUT_WR);until=time.monotonic()+8
        while True:
            pid,status=os.waitpid(self.pid,os.WNOHANG)
            if pid:self.code=os.waitstatus_to_exitcode(status);break
            assert time.monotonic()<until,'owned recorder natural retirement deadline';select.select([self.parent],[],[],.02)
        self.parent.close();assert self.code==0 and not self.path.exists(),'natural exit/socket retirement'
        return self.code

def sql_snapshot():
    db=sqlite3.connect((state/'Conversations/conversations.sqlite3').resolve().as_uri()+'?mode=ro',uri=True,timeout=2)
    try:
        version=db.execute('PRAGMA user_version').fetchone()[0]
        key='herdr_session' if version==1 else 'origin_value'
        rows=db.execute(f'SELECT id,agent,{key},native_session,route_id,pane_id,terminal_id,updated_order,truncated,status,subagents,updated_ms,bytes FROM conversations ORDER BY id').fetchall()
        items=db.execute('SELECT conversation,item_id,ordinal,digest,body FROM items ORDER BY conversation,ordinal').fetchall()
        assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
        assert db.execute('PRAGMA foreign_key_check').fetchall()==[]
        return version,rows,items
    finally:db.close()

def wait_sql(predicate):
    until=time.monotonic()+8
    while True:
        current=sql_snapshot()
        if predicate(current):return current
        assert time.monotonic()<until,'durable fixture deadline'
        select.select([],[],[],.02)

baseline=Recorder(a.baseline,'baseline')
try:
    until=time.monotonic()+8
    while baseline.query('persistence.status').get('mode')!='healthy':assert time.monotonic()<until,'baseline persistence readiness deadline'
    baseline.authority()
    baseline.begin([{'role':'user','content':'hello'}]);baseline.finish('legacy old answer')
    original=wait_sql(lambda v:len(v[1])==1 and bytes(v[1][0][9])==b'complete' and len(v[2])==2)
    assert original[0]==1,'baseline must actually produce SQL v1'
finally:baseline.stop()
original=sql_snapshot();assert original[0]==1
candidate=Recorder(a.candidate,'candidate')
try:
    until=time.monotonic()+8
    while candidate.query('persistence.status').get('mode')!='healthy':
        assert time.monotonic()<until,'candidate persistence readiness deadline'
    migrated=sql_snapshot()
    assert migrated[0]==2 and migrated[1:]==original[1:],'all legacy row/item bytes and IDs preserved by actual recorder migration'
    candidate.authority()
    candidate.begin([{'role':'user','content':'hello'},{'role':'assistant','content':'legacy old answer'},{'role':'user','content':'new prompt'}]);candidate.finish('candidate answer')
    until=time.monotonic()+5
    while True:
        headers=candidate.query('conversations.list')['conversations'];assert len(headers)==1
        page=candidate.query('conversation.read',conversationID=headers[0]['id'])
        if page['summary']['status']=='complete':break
        assert time.monotonic()<until,'candidate completion deadline'
    encoded=json.dumps(page)
    assert 'legacy old answer' in encoded and 'candidate answer' in encoded,'native-scoped restore retains previous history and new response'
finally:candidate.stop()
receipt={'passed':True,'checks':5,'baselineSchema':1,'candidateSchema':2,'legacyRowsAndItemsBytePreserved':True,'nativeRestoreAndAppend':True,'ownedProcessesExited':True,'socketRemoved':not (state/'ac.sock').exists(),'actualProvider':'NOTRUN','app':'NOTRUN','networkCanariesDenied':True,'scriptSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'binaries':{name:hashlib.sha256(path.read_bytes()).hexdigest() for name,path in [('baseline',a.baseline),('candidate',a.candidate)]}}
(a.work/'validation.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS: actual retained v1 recorder archive migration, exact bytes and scoped restore, natural retirement')
