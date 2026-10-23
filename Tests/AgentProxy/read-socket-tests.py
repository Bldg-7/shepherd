#!/usr/bin/env python3
"""Synthetic fd3 tee -> real recorder -> private NDJSON socket. No app/agents,
credentials, transcript files or external network. All sockets under --work.
"""
import argparse, json, os, select, socket, stat, struct, subprocess, time
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--binary', type=Path, required=True)
p.add_argument('--work', type=Path, required=True)
a = p.parse_args()
a.work.mkdir(mode=0o700, parents=True, exist_ok=False)
passed = 0

def check(value, label):
    global passed
    assert value, label
    passed += 1
    print('PASS ' + label, flush=True)

class Reader:
    def __init__(self, sock): self.sock, self.buffer = sock, bytearray()
    def line(self, timeout=3):
        until = time.monotonic() + timeout
        while True:
            index = self.buffer.find(b'\n')
            if index >= 0:
                raw = self.buffer[:index]; del self.buffer[:index + 1]
                return json.loads(raw)
            assert len(self.buffer) <= 2 << 20, 'bounded encoded line'
            left = until - time.monotonic()
            if left <= 0 or not select.select([self.sock], [], [], left)[0]: return None
            chunk = self.sock.recv(65536)
            if not chunk: raise EOFError()
            self.buffer.extend(chunk)

class Recorder:
    def __init__(self, directory, path=None):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.path = path or directory / 'ac.sock'
        self.tee, child = socket.socketpair()
        actions = [(os.POSIX_SPAWN_DUP2, child.fileno(), 3)]
        if child.fileno() != 3: actions.append((os.POSIX_SPAWN_CLOSE, child.fileno()))
        for fd in [1, 2]: actions.append((os.POSIX_SPAWN_OPEN, fd, '/dev/null', os.O_WRONLY, 0o600))
        self.pid = os.posix_spawn(str(a.binary), [str(a.binary), 'recorder', '--socket', str(self.path)], {}, file_actions=actions)
        child.close(); self.tee.settimeout(5); self.status = None
    def wait(self, timeout=5):
        until = time.monotonic() + timeout
        while self.status is None:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid: self.status = os.waitstatus_to_exitcode(status); return self.status
            assert time.monotonic() < until, 'recorder natural exit deadline'
            select.select([self.tee] if self.tee.fileno() >= 0 else [], [], [], min(.02, until-time.monotonic()))
        return self.status
    def connect(self):
        until = time.monotonic() + 5
        while True:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(3)
            try: s.connect(str(self.path)); return s
            except (FileNotFoundError, ConnectionRefusedError):
                s.close()
                pid, status = os.waitpid(self.pid, os.WNOHANG)
                if pid: self.status = os.waitstatus_to_exitcode(status); raise AssertionError('recorder failed before bind')
                assert time.monotonic() < until, 'bind deadline'
                select.select([self.tee], [], [], .02)
    def query(self, method, **params):
        with self.connect() as s:
            s.sendall(json.dumps({'id': 'q', 'method': method, 'params': params}).encode() + b'\n')
            answer = Reader(s).line()
            assert answer is not None, 'reply deadline'
            return answer
    def frame(self, kind, payload=b'', exchange=1):
        if not isinstance(payload, bytes): payload = json.dumps(payload).encode()
        self.tee.sendall(struct.pack('>IBQ', 9 + len(payload), kind, exchange) + payload)
    def event(self, data): self.frame(5, b'data: ' + json.dumps(data).encode() + b'\n\n')
    def begin(self):
        self.frame(1, {'routeID': 'route', 'upstream': 'anthropic', 'method': 'POST', 'path': '/v1/messages',
                      'routeIdentity': {'kind': 'claude', 'session': 'session', 'paneID': 'pane', 'terminalID': 'terminal', 'cliVersion': '2.1.309'},
                      'headers': [['content-type', 'application/json'], ['x-claude-code-session-id', 'native'],
                                  ['x-claude-code-request-class', 'main'], ['x-claude-code-agent-id', 'root'],
                                  ['authorization', 'SYNTHETIC_SOCKET_HEADER_NOT_FOR_HISTORY']]})
        self.frame(2, {'messages': [{'role': 'user', 'content': 'hello'}]}); self.frame(3)
        self.frame(4, {'status': 200, 'headers': [['content-type', 'text/event-stream']]})
        self.event({'type': 'message_start', 'message': {'id': 'm', 'role': 'assistant', 'content': []}})
        self.event({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': 'alpha'}})
    def end(self):
        self.event({'type': 'content_block_stop', 'index': 0}); self.event({'type': 'message_stop'})
        self.frame(6, {'outcome': 'complete'})
    def conversation(self):
        until = time.monotonic() + 3
        while True:
            values = self.query('conversations.list')['result']['conversations']
            if values: return values[0]['id']
            assert time.monotonic() < until, 'captured conversation deadline'
            select.select([self.tee], [], [], .02)
    def stop(self):
        if self.status is not None: self.tee.close(); return self.status
        self.tee.shutdown(socket.SHUT_WR)
        code = self.wait(); self.tee.close(); return code

r = Recorder(a.work / 'normal')
try:
    empty = r.query('conversations.list')['result']
    check(not empty['conversations'], 'fresh recorder empty epoch')
    check(stat.S_IMODE(r.path.stat().st_mode) == 0o600, 'read socket 0600')
    check(stat.S_IMODE(r.path.parent.stat().st_mode) == 0o700, 'private parent 0700')
    r.begin(); cid = r.conversation()
    snapshot = r.query('conversation.read', conversationID=cid)['result']
    check(snapshot['items'][0]['blocks'][0]['text'] == 'hello', 'tee request reaches read socket')
    check('SYNTHETIC_SOCKET_HEADER_NOT_FOR_HISTORY' not in json.dumps(snapshot), 'raw header absent from read DTO')
    check(not r.query('conversations.list', terminalID='other')['result']['conversations'], 'terminal scope filter')
    check(r.query('conversation.read', conversationID=cid, epoch='old')['result']['reset'], 'old epoch reset')
    check(r.query('routes.create').get('error', {}).get('code') == 'unknown_method', 'read socket rejects mutation method')
    sub = r.connect()
    sub.sendall(json.dumps({'id':'s', 'method':'conversation.subscribe', 'params':{'conversationID':cid}}).encode()+b'\n')
    stream = Reader(sub); initial = stream.line()['result']; sequence = initial['seq']; items = initial['items']
    for n in range(30): r.event({'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':str(n)}})
    r.end()
    count = 0; deadline = time.monotonic() + .65
    while time.monotonic() < deadline:
        event = stream.line(deadline-time.monotonic())
        if event is None: break
        count += 1
        check(event['method'] == 'conversation.update', 'subscription uses versioned update envelope')
        update = event['params']
        check(update['seq'] > sequence and update['baseSeq'] == sequence, 'subscription base sequence chains exactly')
        sequence = update['seq']
        if update['reset']: items = update['items']
        else:
            start = next(i for i,v in enumerate(items) if v['id'] == update['replaceFromItemID'])
            items = items[:start] + update['items']
    check(1 <= count <= 8, 'burst coalesces to at most 10Hz')
    check(items[-1]['blocks'][0]['text'] == 'alpha'+''.join(map(str,range(30))), 'live suffix patches reconstruct final text')
    check(items[-1]['status'] == 'complete', 'tee completion reaches subscriber')
    shown = subprocess.run([str(a.binary),'show','--terminal','terminal','--socket',str(r.path)], env={}, capture_output=True, timeout=10)
    check(shown.returncode == 0 and json.loads(shown.stdout)['result']['items'][-1]['blocks'][0]['text'] == items[-1]['blocks'][0]['text'], 'show CLI reads real bounded conversation without spawning a forwarder')
    missing = subprocess.run([str(a.binary),'show','--terminal','missing','--socket',str(r.path)], env={}, capture_output=True, timeout=10)
    check(missing.returncode == 2 and not missing.stdout, 'show CLI reports absent conversation with no fabricated history')
    sub.close()
    with r.connect() as oversized:
        oversized.sendall(b'x' * (65536 + 1))
        try: closed = oversized.recv(1) == b''
        except ConnectionResetError: closed = True
        check(closed, 'oversized NDJSON closes only offending client')
    check(bool(r.query('conversations.list')['result']['conversations']), 'bad read client does not kill recorder')
    inode = r.path.stat().st_ino
    duplicate = Recorder(a.work/'normal')
    check(duplicate.wait() == 4 and r.path.stat().st_ino == inode, 'duplicate recorder cannot steal active listener')
    duplicate.stop()
finally:
    check(r.stop() == 0, 'parent EOF exits recorder naturally')
check(not r.path.exists(), 'own socket removed on exit')

r2 = Recorder(a.work/'normal')
try: check(r2.query('conversations.list')['result']['epoch'] != empty['epoch'], 'restart has fresh epoch and no restored transcript')
finally: check(r2.stop() == 0, 'restarted recorder exits')

bounded = Recorder(a.work/'bounds')
try:
    bounded.query('conversations.list')
    held = [bounded.connect() for _ in range(16)]
    try:
        with bounded.connect() as excess:
            try: rejected = excess.recv(1) == b''
            except ConnectionResetError: rejected = True
            check(rejected, 'seventeenth connection rejected without queued client state')
    finally:
        for connection in held: connection.close()
finally: check(bounded.stop() == 0, 'connection cap test leaves no active clients')

slow = Recorder(a.work/'slow')
try:
    slow.query('conversations.list'); slow.begin()
    for _ in range(25): slow.event({'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'\x01'*4000}})
    slow.end(); cid = slow.conversation()
    # Wait for completion through actual replies, not a fixed sleep.
    until = time.monotonic()+3
    while slow.query('conversation.read', conversationID=cid)['result']['summary']['status'] != 'complete':
        assert time.monotonic() < until
    blocked = slow.connect(); blocked.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,1024)
    events = select.kqueue()
    try:
        events.control([select.kevent(blocked.fileno(), filter=select.KQ_FILTER_READ,
                                     flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_CLEAR)],0,0)
        blocked.sendall(json.dumps({'id':'slow','method':'conversation.subscribe','params':{'conversationID':cid}}).encode()+b'\n')
        check(bool(slow.query('conversations.list')['result']['conversations']), 'slow subscriber does not block other readers')
        # kqueue observes EOF even with unread bytes; don't drain and accidentally
        # make this a fast subscriber. The server's deadline drives the wait.
        eof = False; until = time.monotonic()+7
        while time.monotonic() < until and not eof:
            eof = any(e.flags & select.KQ_EV_EOF for e in events.control(None,8,until-time.monotonic()))
        check(eof, 'stalled subscriber disconnected within bounded write deadline')
    finally: events.close(); blocked.close()
finally: check(slow.stop() == 0, 'slow subscriber cleanup exits naturally')

for mode in ['file', 'symlink', 'active', 'public-directory', 'stale', 'replaced', 'bad-tee']:
    folder = a.work/mode; folder.mkdir(mode=0o700); path = folder/'ac.sock'; other = None
    if mode == 'file': path.write_text('leave me')
    if mode == 'symlink':
        (folder/'target').write_text('leave me'); path.symlink_to(folder/'target')
    if mode in ['active','stale']:
        other = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); other.bind(str(path))
        if mode == 'active': other.listen(1)
        else: other.close(); other = None
    if mode == 'public-directory': folder.chmod(0o755)
    rec = Recorder(folder)
    try:
        if mode in ['file','symlink','active','public-directory']:
            check(rec.wait() == 4, mode+' refused without unsafe unlink/chmod')
            if mode in ['file','symlink']: check(path.read_text() == 'leave me', mode+' original preserved')
            if mode == 'public-directory': check(stat.S_IMODE(folder.stat().st_mode) == 0o755, 'arbitrary parent permission unchanged')
        else:
            rec.query('conversations.list')
            if mode == 'bad-tee': rec.tee.sendall(b'\0\0\0\0'); check(rec.wait() == 3, 'malformed tee fails closed')
            if mode == 'replaced':
                path.unlink(); other = socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); other.bind(str(path)); other.listen(1)
            if mode == 'stale': check(path.is_socket(), 'stale owned socket recovered')
    finally:
        code = rec.stop()
        if mode == 'replaced': check(code == 0 and path.exists(), 'cleanup preserves replacement inode')
        if other: other.close()
    if path.is_socket() or path.is_symlink(): path.unlink()

(a.work/'results.json').write_text(json.dumps({'passed':passed,'failed':0,'actualAgents':'NOTRUN','app':'NOTRUN'}))
print(f'PASS {passed} real recorder read-socket checks')
