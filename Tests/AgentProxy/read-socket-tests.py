#!/usr/bin/env python3
"""Synthetic fd3 tee -> real recorder -> private NDJSON socket. No app/agents,
credentials, transcript files or external network. All sockets under --work.
"""
import argparse, fcntl, json, os, select, socket, stat, struct, subprocess, time
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
    def __init__(self, directory, path=None, state_directory=None):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.path = path or directory / 'ac.sock'
        self.tee, child = socket.socketpair()
        actions = [(os.POSIX_SPAWN_DUP2, child.fileno(), 3)]
        if child.fileno() != 3: actions.append((os.POSIX_SPAWN_CLOSE, child.fileno()))
        for fd in [1, 2]: actions.append((os.POSIX_SPAWN_OPEN, fd, '/dev/null', os.O_WRONLY, 0o600))
        command = [str(a.binary), 'recorder', '--socket', str(self.path)]
        if state_directory is not None: command += ['--state-dir', str(state_directory)]
        self.pid = os.posix_spawn(str(a.binary), command, {}, file_actions=actions)
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
    def reply_frame(self):
        header = bytearray()
        while len(header) < 13:
            part = self.tee.recv(13 - len(header))
            assert part, 'recorder closed before frame reply'
            header.extend(part)
        length, kind, exchange = struct.unpack('>IBQ', header)
        assert 9 <= length <= (1 << 20) + 9, 'bounded reply frame'
        payload = bytearray()
        while len(payload) < length - 9:
            part = self.tee.recv(length - 9 - len(payload))
            assert part, 'recorder closed during frame reply'
            payload.extend(part)
        return kind, exchange, bytes(payload)
    def ack(self, generation):
        ack = bytearray()
        while len(ack) < 13:
            part = self.tee.recv(13 - len(ack))
            assert part, 'recorder closed before authority acknowledgement'
            ack.extend(part)
        assert struct.unpack('>IBQ', ack) == (9, 8, generation), 'correlated empty authority ACK'
    def authority(self, generation=1, routes=True, expect_ack=True):
        identity = {'kind': 'claude', 'session': 'session', 'paneID': 'pane', 'terminalID': 'terminal', 'cliVersion': '2.1.309'}
        self.frame(7, {'generation': generation, 'routes': [{'routeID': 'route', 'identity': identity}] if routes else []}, exchange=0)
        if expect_ack: self.ack(generation)
    def event(self, data, exchange=1): self.frame(5, b'data: ' + json.dumps(data).encode() + b'\n\n', exchange=exchange)
    def begin(self, wait_admission=False):
        self.frame(1, {'routeID': 'route', 'upstream': 'anthropic', 'method': 'POST', 'path': '/v1/messages',
                      'routeIdentity': {'kind': 'claude', 'session': 'session', 'paneID': 'pane', 'terminalID': 'terminal', 'cliVersion': '2.1.309'},
                      'headers': [['content-type', 'application/json'], ['x-claude-code-session-id', 'native'],
                                  ['x-claude-code-request-class', 'main'], ['x-claude-code-agent-id', 'root'],
                                  ['authorization', 'SYNTHETIC_SOCKET_HEADER_NOT_FOR_HISTORY']]})
        self.frame(2, {'messages': [{'role': 'user', 'content': 'hello'}]}); self.frame(3)
        if wait_admission: self.conversation()
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

store_root = a.work / 'persistence-state'
store_root.mkdir(mode=0o700)
persisted = Recorder(a.work / 'persistence-socket', state_directory=store_root)
try:
    persisted.query('conversations.list')
    persisted.authority(); persisted.begin(wait_admission=True); persisted.end(); persisted.conversation()
    index = store_root / 'Conversations' / 'index-v1.json'
    until = time.monotonic() + 10
    while True:
        try:
            entries = json.loads(index.read_bytes())['records']
            if len(entries) == 1:
                payload = (store_root / 'Conversations' / 'records' / (entries[0]['generation'] + '.json')).read_bytes()
                break
        except (OSError, ValueError, KeyError): pass
        assert time.monotonic() < until, 'normalized journal write deadline'
        select.select([persisted.tee], [], [], .02)
    check(len(entries) == 1, 'accepted capture reaches the journal index')
    check(bool(payload), 'index references an owned record')
    check(b'hello' in payload and b'SYNTHETIC_SOCKET_HEADER_NOT_FOR_HISTORY' not in payload,
          'journal contains normalized text, not raw authorization header')
finally:
    check(persisted.stop() == 0, 'synthetic persistence recorder exits')

retained_index = json.loads(index.read_bytes())
reopened = Recorder(a.work / 'persistence-reopen', state_directory=store_root)
try:
    reopened.authority()
    status = reopened.query('persistence.status')['result']
    check(status['mode'] in ('volatile', 'healthy', 'degraded') and status['blockedConversations'] == 0,
          'recorder exposes bounded persistence status without historical content')
    check(not reopened.query('conversations.list')['result']['conversations'], 'no historical exposure before trusted MAIN')
    reopened.begin(wait_admission=True)
    cid = reopened.conversation()
    page = reopened.query('conversation.read', conversationID=cid)['result']
    check(any(block.get('text') == 'alpha' for item in page['items'] for block in item['blocks']),
          'trusted current MAIN restores prior normalized answer')
    reopened.end()
    reopened.authority(generation=2, routes=False)
    check(not reopened.query('conversations.list')['result']['conversations'],
          'revocation ACK fences previously restored readable state')
    check(reopened.query('conversation.read', conversationID=cid)['result'].get('reset'),
          'old restored read ID cannot be reused after revocation ACK')
finally:
    check(reopened.stop() == 0, 'synthetic reopened recorder exits')
reopened_index = json.loads(index.read_bytes())
check(len(reopened_index['records']) == 1 and reopened_index['records'][0]['recordID'] == retained_index['records'][0]['recordID'],
      'restart saves retain the original persistent ID without duplication')

# Two independent producers share one owned root. A refusal cannot be called a
# successful clear: B's already-captured history is preserved and can later be
# saved after A releases its lease. This is precisely why clear is blocked.
shared_root = a.work / 'clear-two-producer-state'
shared_root.mkdir(mode=0o700)
producer_a = Recorder(a.work / 'clear-producer-a', state_directory=shared_root)
producer_b = None
try:
    producer_a.authority(); producer_a.begin(wait_admission=True); producer_a.end(); producer_a.conversation()
    until = time.monotonic() + 10
    while producer_a.query('persistence.status')['result']['mode'] != 'healthy':
        assert time.monotonic() < until, 'producer A journal lease deadline'
        time.sleep(.02)
    index_path = shared_root / 'Conversations' / 'index-v1.json'
    until = time.monotonic() + 10
    while True:
        try:
            initial_index = index_path.read_bytes()
            entries = json.loads(initial_index)['records']
            body = (shared_root / 'Conversations' / 'records' / (entries[0]['generation'] + '.json')).read_bytes()
            if json.loads(body)['records'][0]['status'] == 'complete': break
        except (OSError, ValueError, KeyError, IndexError): pass
        assert time.monotonic() < until, 'producer A completed durable snapshot deadline'
        time.sleep(.02)
    producer_b = Recorder(a.work / 'clear-producer-b', state_directory=shared_root)
    producer_b.authority()
    producer_b.frame(1, {'routeID': 'route', 'upstream': 'anthropic', 'method': 'POST', 'path': '/v1/messages',
                         'routeIdentity': {'kind': 'claude', 'session': 'session', 'paneID': 'pane', 'terminalID': 'terminal', 'cliVersion': '2.1.309'},
                         'headers': [['x-claude-code-session-id', 'producer-b'], ['x-claude-code-request-class', 'main']]})
    producer_b.frame(2, {'messages': [{'role': 'user', 'content': 'owned-producer-b-before-refusal'}]}); producer_b.frame(3)
    b_id = producer_b.conversation()
    until = time.monotonic() + 5
    while producer_b.query('persistence.status')['result']['mode'] != 'degraded':
        assert time.monotonic() < until, 'producer B competing lease deadline'
        time.sleep(.02)
    producer_a.frame(10, exchange=2)
    kind, generation, payload = producer_a.reply_frame()
    check(kind == 11 and generation == 2 and json.loads(payload)['outcome'] == 'unavailable',
          'clear refuses when global producer exclusion is unproved')
    check(index_path.read_bytes() == initial_index, 'refused clear leaves A index bytes untouched')
    page = producer_b.query('conversation.read', conversationID=b_id)['result']
    check(any(block.get('text') == 'owned-producer-b-before-refusal' for item in page['items'] for block in item['blocks']),
          'refused clear leaves B preexisting live capture intact')
    check(producer_a.stop() == 0, 'producer A releases journal lease')
    until = time.monotonic() + 15
    while True:
        try:
            entries = json.loads(index_path.read_bytes())['records']
            bodies = [(shared_root / 'Conversations' / 'records' / (entry['generation'] + '.json')).read_bytes() for entry in entries]
            if any(b'owned-producer-b-before-refusal' in body for body in bodies): break
        except (OSError, ValueError, KeyError): pass
        assert time.monotonic() < until, 'producer B retry after lease release'
        time.sleep(.05)
    check(True, 'pre-refusal producer B can persist only because no clear success was reported')
finally:
    if producer_b is not None: check(producer_b.stop() == 0, 'producer B exits naturally')
    if producer_a.status is None: check(producer_a.stop() == 0, 'producer A exits naturally')

# A second, non-cooperating producer starts against the same root before it
# opens the journal; clear remains denied without depending on a lease probe.
startup_root = a.work / 'clear-startup-state'
startup_root.mkdir(mode=0o700)
first = Recorder(a.work / 'clear-startup-first', state_directory=startup_root)
late = Recorder(a.work / 'clear-startup-late', state_directory=startup_root)
try:
    first.authority()
    late.query('conversations.list')  # child exists, no journal open required
    first.frame(10, exchange=2)
    kind, generation, payload = first.reply_frame()
    check(kind == 11 and generation == 2 and json.loads(payload)['outcome'] == 'unavailable',
          'unproved startup/legacy exclusion cannot produce clear success')
    check(not (startup_root / 'Conversations').exists(), 'refused clear does not even initialize the journal')
finally:
    check(late.stop() == 0, 'simulated noncooperating producer exits')
    check(first.stop() == 0, 'startup-exclusion recorder exits')

# An unconfigured recorder must return an explicit failed-clear frame, never
# a success ACK or mutation of its live epoch.
clear_unavailable = Recorder(a.work / 'clear-unavailable')
try:
    clear_unavailable.authority(); clear_unavailable.frame(10, exchange=2)
    kind, generation, payload = clear_unavailable.reply_frame()
    check(kind == 11 and generation == 2 and json.loads(payload)['outcome'] == 'unavailable',
          'unconfigured clear reports failure rather than synchronized success')
finally:
    check(clear_unavailable.stop() == 0, 'unavailable-clear recorder exits naturally')

# A corrupt future/unknown index is preserved because clear is refused before
# opening the journal, without claiming success.
clear_bad_root = a.work / 'clear-corrupt-state'
clear_bad_root.mkdir(mode=0o700)
clear_bad_dir = clear_bad_root / 'Conversations'
clear_bad_dir.mkdir(mode=0o700)
(clear_bad_dir / 'records').mkdir(mode=0o700)
clear_bad_index = clear_bad_dir / 'index-v1.json'
clear_bad_index.write_bytes(b'{"version":999,"records":[]}')
clear_bad_index.chmod(0o600)
clear_bad = Recorder(a.work / 'clear-corrupt-socket', state_directory=clear_bad_root)
try:
    clear_bad.authority(); clear_bad.frame(10, exchange=2)
    kind, generation, payload = clear_bad.reply_frame()
    check(kind == 11 and generation == 2 and json.loads(payload)['outcome'] == 'unavailable',
          'unsupported index clear is refused before journal access')
    check(clear_bad_index.read_bytes() == b'{"version":999,"records":[]}', 'unsupported index bytes remain preserved')
finally:
    check(clear_bad.stop() == 0, 'corrupt-clear recorder exits naturally')

# Hold the owned journal lease before the recorder opens it, then release it.
# The existing live MAIN must become persistable without another mutation.
locked_root = a.work / 'locked-state'
locked_root.mkdir(mode=0o700)
locked_conversations = locked_root / 'Conversations'
locked_conversations.mkdir(mode=0o700)
(locked_conversations / 'records').mkdir(mode=0o700)
lock_fd = os.open(locked_conversations / 'lock', os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
locked = Recorder(a.work / 'locked-socket', state_directory=locked_root)
try:
    locked.authority(); locked.begin(wait_admission=True); locked.end(); locked.conversation()
    until = time.monotonic() + 5
    while locked.query('persistence.status')['result']['mode'] != 'degraded':
        assert time.monotonic() < until, 'competing journal lease observed'
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    index_path = locked_conversations / 'index-v1.json'
    until = time.monotonic() + 15
    while True:
        try:
            entries = json.loads(index_path.read_bytes())['records']
            if entries: break
        except (OSError, ValueError, KeyError): pass
        assert time.monotonic() < until, 'released journal lease retry deadline'
        time.sleep(.05)
    check(len(entries) == 1, 'released lease retries and persists without another MAIN')
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN); os.close(lock_fd)
    check(locked.stop() == 0, 'lease recovery recorder exits naturally')

# A failed upsert must leave its latest revision dirty. Corrupt no body: make
# the owned records directory temporarily unsafe, then restore its mode.
dirty_root = a.work / 'dirty-state'
dirty_root.mkdir(mode=0o700)
dirty = Recorder(a.work / 'dirty-socket', state_directory=dirty_root)
try:
    dirty.authority()
    dirty.frame(1, {'routeID': 'route', 'upstream': 'anthropic', 'method': 'POST', 'path': '/v1/messages',
                    'routeIdentity': {'kind': 'claude', 'session': 'session', 'paneID': 'pane', 'terminalID': 'terminal', 'cliVersion': '2.1.309'},
                    'headers': [['x-claude-code-session-id', 'native'], ['x-claude-code-request-class', 'main']]})
    dirty.frame(2, {'messages': [{'role': 'user', 'content': 'dirty-input'}]}); dirty.frame(3)
    dirty.conversation()
    until = time.monotonic() + 10
    while dirty.query('persistence.status')['result']['mode'] != 'healthy':
        assert time.monotonic() < until, 'initial dirty fixture save deadline'
        time.sleep(.05)
    records_dir = dirty_root / 'Conversations' / 'records'
    records_dir.chmod(0o755)
    dirty.frame(4, {'status': 200, 'headers': [['content-type', 'text/event-stream']]})
    dirty.event({'type': 'message_start', 'message': {'id': 'm', 'role': 'assistant', 'content': []}})
    dirty.event({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': 'retry-only-answer'}})
    dirty.end()
    until = time.monotonic() + 8
    while dirty.query('persistence.status')['result']['mode'] != 'degraded':
        assert time.monotonic() < until, 'failed write observed before permission repair'
        time.sleep(.05)
    records_dir.chmod(0o700)
    until = time.monotonic() + 15
    while True:
        try:
            entries = json.loads((dirty_root / 'Conversations' / 'index-v1.json').read_bytes())['records']
            body = (records_dir / (entries[0]['generation'] + '.json')).read_bytes()
            if b'retry-only-answer' in body: break
        except (OSError, ValueError, KeyError, IndexError): pass
        assert time.monotonic() < until, 'dirty revision retry deadline'
        time.sleep(.05)
    check(b'retry-only-answer' in body, 'failed latest revision retries without another capture mutation')
finally:
    if (dirty_root / 'Conversations' / 'records').exists(): (dirty_root / 'Conversations' / 'records').chmod(0o700)
    check(dirty.stop() == 0, 'dirty-retry recorder exits naturally')

# Hold owned read-client reservations so the 64 MiB journal workspace cannot
# be admitted, then release them without any further conversation mutation.
pressure_root = a.work / 'pressure-state'
pressure_root.mkdir(mode=0o700)
pressure = Recorder(a.work / 'pressure-socket', state_directory=pressure_root)
held = []
try:
    pressure.authority()
    pressure.frame(1, {'routeID': 'route', 'upstream': 'anthropic', 'method': 'POST', 'path': '/v1/messages',
                       'routeIdentity': {'kind': 'claude', 'session': 'session', 'paneID': 'pane', 'terminalID': 'terminal', 'cliVersion': '2.1.309'},
                       'headers': [['x-claude-code-session-id', 'native'], ['x-claude-code-request-class', 'main']]})
    pressure.frame(2, {'messages': [{'role': 'user', 'content': 'pressure-input'}]}); pressure.frame(3)
    pressure_id = pressure.conversation()
    until = time.monotonic() + 10
    while pressure.query('persistence.status')['result']['mode'] != 'healthy':
        assert time.monotonic() < until, 'pressure fixture initial save deadline'
        time.sleep(.05)
    for n in range(15):
        reader = pressure.connect()
        reader.sendall(json.dumps({'id': 'held-%d' % n, 'method': 'conversation.subscribe', 'params': {'conversationID': pressure_id}}).encode() + b'\n')
        initial = Reader(reader).line()
        assert initial and not initial['result']['reset'], 'workspace pressure reader handshake'
        held.append(reader)
    check(pressure.query('persistence.status')['result']['admittedClients'] == 16,
          'workspace pressure has fifteen handshaken readers plus status client')
    pressure.frame(4, {'status': 200, 'headers': [['content-type', 'text/event-stream']]})
    pressure.event({'type': 'message_start', 'message': {'id': 'm', 'role': 'assistant', 'content': []}})
    pressure.event({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': 'pressure-only-answer'}})
    pressure.end()
    until = time.monotonic() + 8
    while pressure.query('persistence.status')['result']['mode'] != 'degraded':
        assert time.monotonic() < until, 'workspace pressure drop observed'
        time.sleep(.05)
    for client in held: client.close()
    held = []
    records = pressure_root / 'Conversations' / 'records'
    until = time.monotonic() + 15
    while True:
        try:
            entries = json.loads((pressure_root / 'Conversations' / 'index-v1.json').read_bytes())['records']
            body = (records / (entries[0]['generation'] + '.json')).read_bytes()
            if b'pressure-only-answer' in body: break
        except (OSError, ValueError, KeyError, IndexError): pass
        assert time.monotonic() < until, 'pressure-dropped revision retry deadline'
        time.sleep(.05)
    check(b'pressure-only-answer' in body, 'workspace pressure release retries latest revision')
finally:
    for client in held: client.close()
    check(pressure.stop() == 0, 'pressure retry recorder exits naturally')

# Journal initialization errors are sticky and visible, not silently volatile.
bad_root = a.work / 'bad-state-root'
bad_root.write_bytes(b'synthetic-not-a-directory')
bad = Recorder(a.work / 'bad-state-socket', state_directory=bad_root)
try:
    bad.authority(); bad.begin(wait_admission=True)
    until = time.monotonic() + 5
    while True:
        status = bad.query('persistence.status')['result']
        if status['mode'] == 'degraded': break
        assert time.monotonic() < until, 'initial journal failure status deadline'
    check(status['mode'] == 'degraded', 'initial journal open failure reports degraded')
    bad.end()
finally:
    check(bad.stop() == 0, 'failed journal recorder exits naturally')

# A later bad index must degrade an already healthy recorder, and a later
# successful operation must not clear a previous integrity failure silently.
health_root = a.work / 'health-state'
health_root.mkdir(mode=0o700)
health = Recorder(a.work / 'health-socket', state_directory=health_root)
try:
    health.authority(); health.begin(wait_admission=True); health.end(); health.conversation()
    until = time.monotonic() + 10
    while health.query('persistence.status')['result']['mode'] != 'healthy':
        assert time.monotonic() < until, 'successful journal write deadline'
    health_index = health_root / 'Conversations' / 'index-v1.json'
    original = health_index.read_bytes()
    health_index.write_bytes(b'{broken')
    health.frame(1, {'routeID': 'route', 'upstream': 'anthropic', 'method': 'POST', 'path': '/v1/messages',
                     'routeIdentity': {'kind': 'claude', 'session': 'session', 'paneID': 'pane', 'terminalID': 'terminal', 'cliVersion': '2.1.309'},
                     'headers': [['x-claude-code-session-id', 'second-native'], ['x-claude-code-request-class', 'main']]}, exchange=2)
    health.frame(2, {'messages': [{'role': 'user', 'content': 'synthetic'}]}, exchange=2); health.frame(3, exchange=2)
    until = time.monotonic() + 5
    while health.query('persistence.status')['result']['mode'] != 'degraded':
        assert time.monotonic() < until, 'post-success lookup failure status deadline'
    health_index.write_bytes(original)
    until = time.monotonic() + 8
    while True:
        status = health.query('persistence.status')['result']
        if status['blockedConversations'] == 0: break
        assert time.monotonic() < until, 'successful repaired-journal retry deadline'
        time.sleep(.05)
    check(status['mode'] == 'degraded', 'integrity degradation remains sticky after successful retry')
finally:
    check(health.stop() == 0, 'post-success failure recorder exits naturally')

# Normalized text can expand substantially when JSON-encoded. Exercise the
# real capture -> serial journal path with a record larger than the old 8 MiB
# workspace reservation; frames themselves remain within the tee payload cap.
expanded_root = a.work / 'expanded-state'
expanded_root.mkdir(mode=0o700)
expanded = Recorder(a.work / 'expanded-socket', state_directory=expanded_root)
try:
    expanded.query('conversations.list'); expanded.authority()
    expanded.frame(1, {'routeID':'route','upstream':'anthropic','method':'POST','path':'/v1/messages',
                       'routeIdentity':{'kind':'claude','session':'session','paneID':'pane','terminalID':'terminal','cliVersion':'2.1.309'},
                       'headers':[['x-claude-code-session-id','native'],['x-claude-code-request-class','main']]})
    request = json.dumps({'messages':[{'role':'user','content':'\x01' * 65536} for _ in range(40)]}).encode()
    for offset in range(0, len(request), 512 << 10): expanded.frame(2, request[offset:offset + (512 << 10)])
    expanded.frame(3)
    index = expanded_root / 'Conversations' / 'index-v1.json'
    until = time.monotonic() + 30
    while True:
        try:
            records = json.loads(index.read_bytes())['records']
            if records and records[0]['encodedBytes'] > 8 << 20: break
        except (OSError, ValueError, KeyError): pass
        assert time.monotonic() < until, 'expanded record persistence deadline'
        select.select([expanded.tee], [], [], .02)
    check(records[0]['encodedBytes'] <= 32 << 20, 'expanded normalized record stays within journal cap')
finally:
    check(expanded.stop() == 0, 'expanded synthetic recorder exits')

# Multipart authority does not acknowledge or apply a partial legacy table.
chunked = Recorder(a.work / 'authority-chunked')
try:
    chunked.query('conversations.list')
    identity = {'kind': 'claude', 'session': 'session', 'paneID': 'pane', 'terminalID': 'terminal', 'cliVersion': '2.1.309'}
    chunked.frame(9, {'generation': 1, 'index': 0, 'count': 2, 'routes': [{'routeID': 'route', 'identity': identity}]}, exchange=0)
    check(not select.select([chunked.tee], [], [], .1)[0], 'partial authority is not acknowledged')
    check(not chunked.query('conversations.list')['result']['conversations'], 'partial authority exposes no conversation')
    chunked.frame(9, {'generation': 1, 'index': 1, 'count': 2, 'routes': [{'routeID': 'other', 'identity': identity}]}, exchange=0)
    chunked.ack(1)
    chunked.begin(); chunked.end(); chunked.conversation()
    check(True, 'completed multipart authority admits an authorized current route')
finally:
    check(chunked.stop() == 0, 'multipart authority recorder exits')

# Exercise maximum route count and field bounds while the old snapshot remains
# resident. Status exposes admission accounting, not allocator RSS.
large_root = a.work / 'authority-large-state'
large_root.mkdir(mode=0o700)
large = Recorder(a.work / 'authority-large', state_directory=large_root)
try:
    large.authority()
    old = large.query('persistence.status')['result']
    check(old['authorityRetainedBytes'] == 8 << 20, 'applied authority remains admission-accounted')
    field = 'x' * 256
    big_identity = {'kind': 'claude', 'session': field, 'paneID': field, 'terminalID': field, 'cliVersion': field}
    routes = [{'routeID': 'route', 'identity': identity}] + [
        {'routeID': 'owned-%04d' % i, 'identity': big_identity} for i in range(1, 1024)]
    large.frame(9, {'generation': 2, 'index': 0, 'count': 16, 'routes': routes[:64]}, exchange=0)
    until = time.monotonic() + 3
    while True:
        during = large.query('persistence.status')['result']
        if during['authorityAssemblyBytes'] == 8 << 20: break
        assert time.monotonic() < until, 'partial assembly reservation barrier deadline'
        time.sleep(.02)
    check(during['authorityRetainedBytes'] == 8 << 20 and during['captureReservedBytes'] >= 16 << 20,
          'old authority and partial replacement are simultaneously reserved')
    check(not select.select([large.tee], [], [], 0)[0], 'partial snapshot sends no early ACK')
    for n in range(1, 16):
        large.frame(9, {'generation': 2, 'index': n, 'count': 16, 'routes': routes[n*64:(n+1)*64]}, exchange=0)
    large.ack(2)
    until = time.monotonic() + 3
    while True:
        after = large.query('persistence.status')['result']
        if after['captureReservedBytes'] < 40 << 20: break
        assert time.monotonic() < until, 'old authority reservation release deadline'
        time.sleep(.05)
    check(after['authorityRetainedBytes'] == 8 << 20, 'replacement retains its bounded authority reservation')
    large.begin(wait_admission=True); large.end()
    until = time.monotonic() + 10
    while large.query('persistence.status')['result']['mode'] != 'healthy':
        assert time.monotonic() < until, 'journal admission with retained near-limit authority deadline'
        time.sleep(.05)
    check(True, 'journal and read clients can be admitted with retained near-limit authority')
finally:
    check(large.stop() == 0, 'near-limit authority recorder exits')

# Replacement uses pre-reserved headroom while reader reservations are held.
# First drain unrelated clients, then count all 15 held readers plus the status
# request itself; a byte threshold alone cannot establish client admission.
replacement_pressure = Recorder(a.work / 'authority-replacement-pressure')
held_readers = []
try:
    replacement_pressure.authority(); replacement_pressure.begin(); live_id = replacement_pressure.conversation()
    until = time.monotonic() + 3
    while replacement_pressure.query('persistence.status')['result']['admittedClients'] != 1:
        assert time.monotonic() < until, 'preexisting clients drained before reader barrier'
        time.sleep(.02)
    for n in range(15):
        reader = replacement_pressure.connect()
        reader.sendall(json.dumps({'id': 'held-%d' % n, 'method': 'conversation.subscribe', 'params': {'conversationID': live_id}}).encode() + b'\n')
        initial = Reader(reader).line()
        assert initial and not initial['result']['reset'], 'held reader admission handshake'
        held_readers.append(reader)
    held_status = replacement_pressure.query('persistence.status')['result']
    check(held_status['admittedClients'] == 16, 'fifteen handshaken held readers plus status client are admitted')
    replacement_pressure.frame(9, {'generation': 2, 'index': 0, 'count': 2,
                                   'routes': [{'routeID': 'route', 'identity': identity}]}, exchange=0)
    until = time.monotonic() + 3
    while replacement_pressure.query('persistence.status')['result']['authorityAssemblyBytes'] != 8 << 20:
        assert time.monotonic() < until, 'reader-pressure multipart barrier'
        time.sleep(.02)
    check(not select.select([replacement_pressure.tee], [], [], 0)[0], 'incomplete authority sends no early ACK')
    replacement_pressure.frame(9, {'generation': 2, 'index': 1, 'count': 2,
                                   'routes': [{'routeID': 'other', 'identity': identity}]}, exchange=0)
    replacement_pressure.ack(2)
    for reader in held_readers: reader.close()
    held_readers = []
    replacement_pressure.end()
    cid = replacement_pressure.conversation()
    captured = replacement_pressure.query('conversation.read', conversationID=cid)['result']
    check(any(block.get('text') == 'alpha' for item in captured['items'] for block in item['blocks']),
          'unrelated deferred authority preserves the live response')
finally:
    for reader in held_readers: reader.close()
    check(replacement_pressure.stop() == 0, 'headroom-protected unrelated authority exits normally')

revocation_pressure = Recorder(a.work / 'authority-revocation-pressure')
held_readers = []
try:
    revocation_pressure.authority(); revocation_pressure.begin(); old_id = revocation_pressure.conversation()
    until = time.monotonic() + 3
    while revocation_pressure.query('persistence.status')['result']['admittedClients'] != 1:
        assert time.monotonic() < until, 'revocation preexisting clients drained'
        time.sleep(.02)
    for n in range(15):
        reader = revocation_pressure.connect()
        reader.sendall(json.dumps({'id': 'held-%d' % n, 'method': 'conversation.subscribe', 'params': {'conversationID': old_id}}).encode() + b'\n')
        initial = Reader(reader).line()
        assert initial and not initial['result']['reset'], 'revocation held reader handshake'
        held_readers.append(reader)
    check(revocation_pressure.query('persistence.status')['result']['admittedClients'] == 16,
          'revocation fixture has fifteen handshaken readers plus status client')
    revocation_pressure.frame(7, {'generation': 2, 'routes': []}, exchange=0)
    revocation_pressure.ack(2)
    for reader in held_readers: reader.close()
    held_readers = []
    check(not revocation_pressure.query('conversations.list')['result']['conversations'], 'revocation ACK fences old live capture')
    check(revocation_pressure.query('conversation.read', conversationID=old_id)['result']['reset'], 'old read ticket fails after deferred revocation ACK')
finally:
    for reader in held_readers: reader.close()
    check(revocation_pressure.stop() == 0, 'headroom-protected revocation exits normally')

# Five live exchanges consume 80 MiB. Queue the authority snapshot and then
# their completion frames on the same tee stream: the reader must not wait on
# those post-snapshot frames to make replacement capacity available.
def five_open_snapshot(name, revoke):
    child = Recorder(a.work / name)
    try:
        child.authority()
        for n in range(1, 6):
            child.frame(1, {'routeID': 'route', 'upstream': 'anthropic', 'method': 'POST', 'path': '/v1/messages',
                            'routeIdentity': identity,
                            'headers': [['x-claude-code-session-id', 'five-%d' % n], ['x-claude-code-request-class', 'main']]}, exchange=n)
        new_routes = [] if revoke else [{'routeID': 'route', 'identity': identity}, {'routeID': 'other', 'identity': identity}]
        child.frame(7, {'generation': 2, 'routes': new_routes}, exchange=0)
        for n in range(1, 6):
            child.frame(2, {'messages': [{'role': 'user', 'content': 'owned-%d' % n}]}, exchange=n)
            child.frame(3, exchange=n)
            child.frame(4, {'status': 200, 'headers': [['content-type', 'text/event-stream']]}, exchange=n)
            child.event({'type': 'message_start', 'message': {'id': 'm-%d' % n, 'role': 'assistant', 'content': []}}, exchange=n)
            child.event({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': 'reply-%d' % n}}, exchange=n)
            child.event({'type': 'content_block_stop', 'index': 0}, exchange=n)
            child.event({'type': 'message_stop'}, exchange=n)
            child.frame(6, {'outcome': 'complete'}, exchange=n)
        # A subsequent acknowledged snapshot is an ordered tee-stream barrier
        # proving the five completion sequences were consumed before queries.
        child.frame(7, {'generation': 3, 'routes': new_routes}, exchange=0)
        child.ack(2); child.ack(3)
        until = time.monotonic() + 5
        while True:
            entries = child.query('conversations.list')['result']['conversations']
            if revoke or len(entries) == 5: break
            assert time.monotonic() < until, 'five queued exchanges completed deadline'
            time.sleep(.02)
        if revoke:
            check(not entries, 'revocation ACK rejects post-snapshot old-exchange completions')
        else:
            check(len(entries) == 5, 'unrelated snapshot allows all five queued exchanges to complete')
            for entry in entries:
                until = time.monotonic() + 5
                while True:
                    page = child.query('conversation.read', conversationID=entry['id'])['result']
                    if any(block.get('text', '').startswith('reply-') for item in page['items'] for block in item['blocks']): break
                    assert time.monotonic() < until, 'queued response completion deadline'
                    time.sleep(.02)
                check(True, 'each owned post-snapshot response survived')
    finally:
        check(child.stop() == 0, 'five-exchange headroom recorder exits')
five_open_snapshot('authority-five-unrelated', False)
five_open_snapshot('authority-five-revocation', True)

partial_eof = Recorder(a.work / 'authority-partial-eof')
try:
    partial_eof.frame(9, {'generation': 1, 'index': 0, 'count': 2, 'routes': [{'routeID': 'route', 'identity': identity}]}, exchange=0)
    partial_eof.tee.shutdown(socket.SHUT_WR)
    check(partial_eof.wait() == 3, 'EOF during multipart authority is protocol failure')
    check(partial_eof.tee.recv(1) == b'', 'incomplete authority sends no ACK')
finally:
    partial_eof.stop()

truncated = Recorder(a.work / 'authority-truncated-frame')
try:
    truncated.tee.sendall(struct.pack('>IBQ', 12, 7, 0) + b'{')
    truncated.tee.shutdown(socket.SHUT_WR)
    check(truncated.wait() == 3, 'EOF within an individual frame is protocol failure')
    check(truncated.tee.recv(1) == b'', 'truncated frame sends no ACK')
finally:
    truncated.stop()

oversized_frame = Recorder(a.work / 'authority-oversized-frame')
try:
    oversized_frame.tee.sendall(struct.pack('>I', (1 << 20) + 10))
    check(oversized_frame.wait() == 3, 'oversized framed payload fails closed before buffering')
    check(oversized_frame.tee.recv(1) == b'', 'oversized frame sends no ACK')
finally:
    oversized_frame.stop()

oversized_field = Recorder(a.work / 'authority-oversized-field')
try:
    invalid = dict(identity); invalid['session'] = 'x' * 257
    oversized_field.frame(7, {'generation': 1, 'routes': [{'routeID': 'route', 'identity': invalid}]}, exchange=0)
    check(oversized_field.wait() == 3, 'oversized authority identity fails closed')
finally:
    oversized_field.stop()

oversized_part_field = Recorder(a.work / 'authority-oversized-part-field')
try:
    oversized_part_field.frame(9, {'generation': 1, 'index': 0, 'count': 2,
                                   'routes': [{'routeID': 'route', 'identity': invalid}]}, exchange=0)
    check(oversized_part_field.wait() == 3, 'oversized field is rejected before multipart retention')
    check(oversized_part_field.tee.recv(1) == b'', 'oversized part sends no ACK')
finally:
    oversized_part_field.stop()

chunk_desync = Recorder(a.work / 'authority-chunk-desync')
try:
    chunk_desync.frame(9, {'generation': 1, 'index': 1, 'count': 2, 'routes': [{'routeID': 'route', 'identity': identity}]}, exchange=0)
    check(chunk_desync.wait() == 3, 'out-of-order authority part fails closed')
finally:
    chunk_desync.stop()

desync = Recorder(a.work / 'authority-desync')
try:
    desync.query('conversations.list')
    desync.authority(generation=1)
    desync.authority(generation=1, expect_ack=False)
    check(desync.wait() == 3, 'replayed authority generation terminates recorder fail-closed')
finally:
    desync.stop()

wrong_direction = Recorder(a.work / 'authority-wrong-direction')
try:
    wrong_direction.query('conversations.list')
    wrong_direction.authority()
    wrong_direction.frame(8, exchange=1)
    check(wrong_direction.wait() == 3, 'reverse-direction ACK terminates recorder fail-closed')
finally:
    wrong_direction.stop()

r = Recorder(a.work / 'normal')
try:
    empty = r.query('conversations.list')['result']
    check(not empty['conversations'], 'fresh recorder empty epoch')
    check(r.query('persistence.status')['result']['mode'] == 'off', 'status reports persistence not configured')
    check(stat.S_IMODE(r.path.stat().st_mode) == 0o600, 'read socket 0600')
    check(stat.S_IMODE(r.path.parent.stat().st_mode) == 0o700, 'private parent 0700')
    r.authority()
    r.begin(); cid = r.conversation()
    snapshot = r.query('conversation.read', conversationID=cid)['result']
    check(snapshot['items'][0]['blocks'][0]['text'] == 'hello', 'tee request reaches read socket')
    check('SYNTHETIC_SOCKET_HEADER_NOT_FOR_HISTORY' not in json.dumps(snapshot), 'raw header absent from read DTO')
    check(not r.query('conversations.list', terminalID='other')['result']['conversations'], 'terminal scope filter')
    check(r.query('conversation.read', conversationID=cid, epoch='old')['result']['reset'], 'old epoch reset')
    check(r.query('routes.create').get('error', {}).get('code') == 'unknown_method', 'read socket rejects mutation method')
    check(r.query('conversation.clearSaved').get('error', {}).get('code') == 'unknown_method', 'read socket cannot clear history')
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
    r.frame(1, {'routeID':'route','upstream':'anthropic','method':'POST','path':'/v1/messages',
                'routeIdentity':{'kind':'claude','session':'session','paneID':'pane','terminalID':'terminal','cliVersion':'2.1.309'},
                'headers':[['x-claude-code-session-id','native'],['x-claude-code-request-class','subagent'],
                           ['x-claude-code-agent-id','child'],['x-claude-code-parent-agent-id','root']]}, exchange=2)
    r.frame(2, {'messages':[{'role':'user','content':'private child instructions'}]}, exchange=2); r.frame(3,exchange=2)
    r.frame(4, {'status':200,'headers':[['content-type','text/event-stream']]}, exchange=2)
    r.event({'type':'message_start','message':{'id':'child-message','role':'assistant','content':[]}},2)
    r.event({'type':'content_block_start','index':0,'content_block':{'type':'text','text':'child result'}},2)
    r.event({'type':'content_block_stop','index':0},2)
    r.event({'type':'message_delta','delta':{'stop_reason':'end_turn'}},2)
    r.event({'type':'message_stop'},2); r.frame(6,{'outcome':'complete'},exchange=2)
    until=time.monotonic()+3
    while True:
        child_page=r.query('conversation.read',conversationID=cid)['result']
        if child_page['summary']['subagents']['withFinalResult']==1: break
        assert time.monotonic()<until,'child capture deadline'
        select.select([r.tee],[],[],.02)
    check(child_page['items'][-1]['origin']=='subagent' and child_page['items'][-1]['subagentID']=='child','real socket exposes typed final child result')
    check('private child instructions' not in json.dumps(child_page),'real socket omits child request history')
    with r.connect() as oversized:
        oversized.sendall(b'x' * (65536 + 1))
        try: closed = oversized.recv(1) == b''
        except ConnectionResetError: closed = True
        check(closed, 'oversized NDJSON closes only offending client')
    before_revocation = r.query('conversations.list')['result']['epoch']
    r.authority(generation=2, routes=False)
    until = time.monotonic() + 3
    while True:
        revoked = r.query('conversations.list')['result']
        if revoked['epoch'] != before_revocation: break
        assert time.monotonic() < until, 'authority revocation deadline'
        select.select([r.tee], [], [], .02)
    check(not revoked['conversations'], 'route revocation rotates epoch and drops readable capture')
    r.frame(1, {'routeID':'route','upstream':'anthropic','method':'POST','path':'/v1/messages',
                'routeIdentity':{'kind':'claude','session':'session','paneID':'pane','terminalID':'terminal','cliVersion':'2.1.309'},
                'headers':[['x-claude-code-session-id','native'],['x-claude-code-request-class','main']]}, exchange=3)
    r.frame(2, {'messages':[{'role':'user','content':'stale'}]}, exchange=3); r.frame(3, exchange=3)
    check(not r.query('conversations.list')['result']['conversations'], 'removed route cannot reopen via historical identity')
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
    slow.query('conversations.list'); slow.authority(); slow.begin()
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
