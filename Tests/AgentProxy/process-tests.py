#!/usr/bin/env python3
"""The built hrdrhrdrhrdr-agent-proxy as launchd would run it, with its state
folder and control socket under --work. Only requests the proxy must refuse
before connecting anywhere are sent to its listener (and the runner keeps this
script in a sandbox that allows no connection beyond 127.0.0.1). No app,
launchctl, herdr or agent.

    process-tests.py --binary <hrdrhrdrhrdr-agent-proxy> --work <new folder>
"""
import argparse, hashlib, json, os, signal, socket, stat, subprocess, sys, time
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--binary', type=Path, required=True)
p.add_argument('--work', type=Path, required=True)
a = p.parse_args()
binary = a.binary.resolve(); work = a.work.resolve()
work.mkdir(parents=True, exist_ok=False)
running = []
needles = []
results = []


def start(name, state, sock, extra=()):
    log = open(work / (name + '.log'), 'ab')
    proc = subprocess.Popen([str(binary), '--state-dir', str(state), '--control-socket', str(sock), *extra],
                            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
    running.append(proc)
    return proc


def wait_for(condition, seconds=5.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return condition()


def call(sock, method, params=None, ident='1'):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(5)
        s.connect(str(sock))
        s.sendall((json.dumps({'id': ident, 'method': method, 'params': params or {}}) + '\n').encode())
        data = b''
        while not data.endswith(b'\n'):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    return json.loads(data)


def result(sock, method, params=None):
    answer = call(sock, method, params)
    assert 'result' in answer, f'{method} answered with an error'
    return answer['result']


def answers(sock):
    try:
        return call(sock, 'proxy.status').get('result') is not None
    except OSError:
        return False


def mode(path):
    return stat.S_IMODE(os.lstat(path).st_mode)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def http(port, data):
    with socket.create_connection(('127.0.0.1', port), timeout=5) as s:
        s.sendall(data)
        return s.recv(65536).split(b'\r\n', 1)[0]


def case(name):
    def wrap(function):
        started = time.monotonic()
        try:
            function()
            results.append({'name': name, 'passed': True})
            print(f'PASS {name} ({time.monotonic() - started:.2f}s)', flush=True)
        except Exception as error:  # noqa: BLE001 - every failure is reported
            results.append({'name': name, 'passed': False})
            print(f'FAIL {name}: {type(error).__name__}: {error}', flush=True)
        return function
    return wrap


main_state, main_sock = work / 'main/state', work / 'main/ap.sock'
remembered = {}


@case('start-folder-socket-and-status')
def _():
    proc = start('main', main_state, main_sock)
    assert wait_for(main_sock.exists), 'ap.sock appears'
    assert mode(main_state) == 0o700 and mode(main_sock) == 0o600, 'state folder 0700, ap.sock 0600'
    saved = json.loads((main_state / 'state.json').read_text())
    assert mode(main_state / 'state.json') == 0o600 and 20000 <= saved['port'] <= 32767, 'state.json 0600 with a port in range'
    status = result(main_sock, 'proxy.status')
    assert status['port'] == saved['port'] and status['protocolVersion'] == 1 and status['state'] == 'running', 'status'
    assert status['build'] == hashlib.sha256(binary.read_bytes()).hexdigest(), 'build is the executable SHA-256'
    assert status['recorder']['state'] == 'running' and status['recorder']['pid'] > 0, 'recorder running'
    route = result(main_sock, 'routes.create', {'kind': 'claude', 'session': 'default', 'paneID': 'w1:p1',
                                                'terminalID': 't1', 'cliVersion': '2.1.306'})
    token = route['baseURL'].rsplit('/', 1)[1]
    needles.append(token)
    assert route['baseURL'] == f'http://127.0.0.1:{saved["port"]}/p/{token}', 'baseURL'
    stored = (main_state / 'routes.json').read_bytes()
    assert mode(main_state / 'routes.json') == 0o600, 'routes.json 0600'
    assert hashlib.sha256(token.encode()).hexdigest().encode() in stored and token.encode() not in stored, 'routes.json keeps the hash only'
    port = saved['port']
    line = http(port, f'GET /p/{token}/v1/models HTTP/1.1\r\nHost: localhost:{port}\r\n\r\n'.encode())
    assert line == b'HTTP/1.1 403 Forbidden', 'a foreign Host is refused'
    line = http(port, f'GET /p/{token}/backend-api/codex/responses HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n'
                      'Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n'.encode())
    assert line == b'HTTP/1.1 426 Upgrade Required', 'a WebSocket upgrade is refused'
    line = http(port, f'POST /p/{token}/backend-api/codex/responses HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n'
                      'Content-Length: 0\r\n\r\n'.encode())
    assert line == b'HTTP/1.1 404 Not Found', 'a claude route has no chatgpt.com path'
    remembered.update(proc=proc, port=port, routeID=route['routeID'], token=token)


@case('second-instance-refused')
def _():
    other = start('second', work / 'second/state', main_sock)
    assert other.wait(timeout=10) != 0, 'a second proxy on the same socket exits with an error'
    assert b'another agent proxy' in (work / 'second.log').read_bytes(), 'and says why'
    assert result(main_sock, 'proxy.status')['state'] == 'running', 'the first one still answers'


@case('recorder-restarted-after-kill')
def _():
    first = result(main_sock, 'proxy.status')['recorder']['pid']
    os.kill(first, signal.SIGKILL)
    assert wait_for(lambda: (r := result(main_sock, 'proxy.status')['recorder'])['state'] == 'running'
                    and r['pid'] not in (None, first) and r['restarts'] >= 1), 'a new recorder'
    assert wait_for(lambda: not alive(first), 2), 'the old one is gone'


@case('restart-when-idle-exits')
def _():
    proc = remembered['proc']
    recorder = result(main_sock, 'proxy.status')['recorder']['pid']
    answer = result(main_sock, 'proxy.restartWhenIdle')
    assert answer == {'accepted': True, 'inFlight': 0}, 'accepted, nothing in flight'
    assert proc.wait(timeout=5) == 0, 'exits with 0'
    assert not main_sock.exists(), 'its socket is removed'
    assert wait_for(lambda: not alive(recorder), 3), 'its recorder exits too'


@case('restart-keeps-port-and-routes')
def _():
    proc = start('main-again', main_state, main_sock)
    assert wait_for(main_sock.exists), 'ap.sock appears'
    status = result(main_sock, 'proxy.status')
    assert status['port'] == remembered['port'], 'the same port'
    routes = result(main_sock, 'routes.list')['routes']
    assert [r['routeID'] for r in routes] == [remembered['routeID']], 'the route survived'
    recorder = status['recorder']['pid']
    proc.send_signal(signal.SIGTERM)
    assert proc.wait(timeout=5) == 0, 'SIGTERM: exits with 0'
    assert wait_for(lambda: not alive(recorder), 3), 'its recorder exits too'


@case('stale-socket-replaced')
def _():
    stale = socket.socket(socket.AF_UNIX)
    stale.bind(str(main_sock))
    stale.close()  # a socket file no one answers on
    proc = start('main-stale', main_state, main_sock)
    assert wait_for(lambda: answers(main_sock)), 'started over a stale socket'
    proc.send_signal(signal.SIGTERM)
    assert proc.wait(timeout=5) == 0


@case('taken-port-replaced')
def _():
    state = work / 'taken/state'
    state.mkdir(parents=True, mode=0o700)
    holder = socket.socket()
    holder.bind(('127.0.0.1', 0))
    holder.listen(1)
    taken = holder.getsockname()[1]
    if not 20000 <= taken <= 32767:
        holder.close()
        for candidate in range(24000, 24100):
            holder = socket.socket()
            try:
                holder.bind(('127.0.0.1', candidate)); holder.listen(1); taken = candidate; break
            except OSError:
                holder.close()
    (state / 'state.json').write_text(json.dumps({'version': 1, 'port': taken}))
    os.chmod(state / 'state.json', 0o600)
    sock = work / 'taken/ap.sock'
    proc = start('taken', state, sock)
    assert wait_for(sock.exists, 10), 'started after the saved port stayed taken'
    port = result(sock, 'proxy.status')['port']
    assert port != taken and json.loads((state / 'state.json').read_text())['port'] == port, 'another port, saved'
    holder.close()
    proc.send_signal(signal.SIGTERM)
    assert proc.wait(timeout=5) == 0


@case('wide-folder-narrowed')
def _():
    state = work / 'wide/state'
    state.mkdir(parents=True)
    os.chmod(state, 0o755)
    sock = work / 'wide/ap.sock'
    proc = start('wide', state, sock)
    assert wait_for(sock.exists), 'started'
    assert mode(state) == 0o700, 'narrowed to 0700'
    proc.send_signal(signal.SIGTERM)
    assert proc.wait(timeout=5) == 0


@case('symlinked-folder-refused')
def _():
    target = work / 'link/target'
    target.mkdir(parents=True)
    (work / 'link/state').symlink_to(target)
    sock = work / 'link/ap.sock'
    proc = start('link', work / 'link/state', sock)
    assert proc.wait(timeout=10) != 0, 'exits with an error'
    assert b'symbolic link' in (work / 'link.log').read_bytes(), 'and says why'
    assert list(target.iterdir()) == [] and not sock.exists(), 'nothing written'


@case('long-socket-path-refused')
def _():
    folder = work / ('l' * 60)
    folder.mkdir()
    sock = folder / (('s' * 40) + '.sock')
    assert len(str(sock).encode()) > 103
    proc = start('long', work / 'long/state', sock)
    assert proc.wait(timeout=10) != 0, 'exits with an error'
    assert b'control socket' in (work / 'long.log').read_bytes(), 'and says why'


@case('relative-path-refused')
def _():
    proc = start('relative', Path('relative/state'), work / 'r.sock')
    assert proc.wait(timeout=10) == 64, 'usage error'


@case('outputs-hold-no-token')
def _():
    for log in work.glob('*.log'):
        data = log.read_bytes()
        assert not any(n.encode() in data for n in needles), f'a token in {log.name}'


for proc in running:
    if proc.poll() is None:
        proc.kill()
        proc.wait()
(work / 'needles.json').write_text(json.dumps(needles))
os.chmod(work / 'needles.json', 0o600)
failed = sum(not r['passed'] for r in results)
(work / 'results.json').write_text(json.dumps({'cases': results, 'passed': len(results) - failed, 'failed': failed}, indent=2))
print(f'{len(results) - failed} passed, {failed} failed', flush=True)
sys.exit(1 if failed else 0)
