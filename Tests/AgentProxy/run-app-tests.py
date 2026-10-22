#!/usr/bin/env python3
"""The app's side of the agent proxy (SHPHRD-105), without the app, launchd,
SMAppService, herdr, an agent or the network:

  run-app-tests.py --output <new folder> --app <Debug build's hrdrhrdrhrdr.app>

1. AppServiceTests: AgentProxyService and the ap.sock client against a
   stand-in proxy on a Unix socket under the output folder, with a stand-in
   LaunchAgent (registration, turning off once the agents using it are gone,
   another build asked to restart, routes of panes that are gone, kinds of
   agent turned away for their sign-in, the CLI version floors).
   AgentProxyService+System.swift, which holds SMAppService and This Mac's
   herdr, is not built into it.
2. check-bundle.py on the Debug build: the executable and its LaunchAgent as
   the app carries them, read from the files.
3. The executable in the built app, run where it is with its state folder and
   control socket under the output folder, as Tests/AgentProxy's
   process-tests.py runs it, with nothing but the proxy itself allowed to be
   started; then once more with a state folder given as "~/…".

The test stages run under sandbox-exec with no connection allowed but to
127.0.0.1 and Unix sockets, and no name lookups.
"""
import argparse, hashlib, json, os, platform, plistlib, signal, socket, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
p.add_argument('--app', type=Path, required=True)
a = p.parse_args()
out = a.output.resolve(); out.mkdir(parents=True, exist_ok=False, mode=0o700)
app = a.app.resolve()
for name in ['home', 'tmp', 'cache', 'run', 'h']:
    (out / name).mkdir(mode=0o700)
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer', HOME=str(out / 'home'),
           CFFIXED_USER_HOME=str(out / 'home'), TMPDIR=str(out / 'tmp'), CLANG_MODULE_CACHE_PATH=str(out / 'cache'))
records = []


def stage(name, seconds, command, extra_env=None):
    log = out / (name + '.log')
    with open(log, 'wb') as handle:
        process = subprocess.Popen(command, cwd=ROOT, env={**env, **(extra_env or {})}, stdout=handle, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            code = process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL); process.wait()
            raise SystemExit(f'{name}: timed out\n' + log.read_text(errors='replace')[-4000:])
    try:
        os.killpg(process.pid, 0)
        raise SystemExit(f'{name}: left processes behind')
    except ProcessLookupError:
        pass
    if code != 0:
        raise SystemExit(f'{name}: exit {code}\n' + log.read_text(errors='replace')[-6000:])
    records.append(name)
    return log.read_text(errors='replace')


executable = app / 'Contents/MacOS/hrdrhrdrhrdr-agent-proxy'
main = app / 'Contents/MacOS' / plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleExecutable']
profile = out / 'sandbox.sb'
# Loopback and Unix sockets only, no name lookups, and of the app's
# executables only the proxy may be started.
profile.write_text('(version 1)\n(allow default)\n(deny network-outbound)\n'
                   '(allow network-outbound (remote ip "localhost:*"))\n'
                   '(allow network-outbound (remote unix-socket))\n'
                   '(deny network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))\n'
                   f'(deny process-exec (subpath {json.dumps(str(app))}))\n'
                   f'(allow process-exec (literal {json.dumps(str(executable))}))\n')
sandboxed = ['/usr/bin/sandbox-exec', '-f', str(profile)]

kit = 'ShepherdKit/Sources/ShepherdKit'
protocol = sorted(str(x.relative_to(ROOT)) for x in (ROOT / 'AgentProxy/Sources/AgentProxyProtocol').glob('*.swift'))
service = ['Shepherd/AgentProxy/AgentProxyService.swift', 'Shepherd/AgentProxy/AgentProxyControlClient.swift',
           'Shepherd/AgentProxy/AgentProxyLaunchAgent.swift', 'Shepherd/AgentProxy/AgentProxyInjectionPolicy.swift',
           'Shepherd/Agents/AgentProxyRouting.swift', 'Shepherd/Agents/AgentRuntime.swift']
sources = [f'{kit}/Resources.swift', f'{kit}/Agents/AgentKind.swift', f'{kit}/Machines/Machine.swift', *protocol, *service,
           'Tests/AgentProxy/App/AppServiceTests.swift']
system = 'Shepherd/AgentProxy/AgentProxyService+System.swift'
assert sorted(str(x.relative_to(ROOT)) for x in (ROOT / 'Shepherd/AgentProxy').glob('*.swift')) == sorted(service[:4] + [system])
for name in service + ['Tests/AgentProxy/App/AppServiceTests.swift']:
    text = (ROOT / name).read_text()
    for forbidden in ['SMAppService', 'launchctl', 'UserDefaults', 'LocalHerdrTransport', 'CFNetworkCopySystemProxySettings']:
        assert forbidden not in text, (name, forbidden)
identity = sources + [system, 'Tests/AgentProxy/run-app-tests.py', 'Tests/AgentProxy/check-bundle.py', 'Tests/AgentProxy/process-tests.py',
                      'Config/LaunchAgents/com.bldg-7.shepherd.agent-proxy.plist', 'Config/LaunchAgents/com.bldg-7.shepherd.agent-proxy.debug.plist']
hashes = {n: hashlib.sha256((ROOT / n).read_bytes()).hexdigest() for n in sorted(set(identity))}
(out / 'source-hashes.json').write_text(json.dumps(hashes, indent=2))

# Failure messages introduced by fail-closed build/route verification.
strings = json.loads((ROOT / 'Shepherd/Localizable.xcstrings').read_text())['strings']
for key in ['The bundled proxy could not be verified. Agents start without it.',
            'The proxy isn’t answering. It will stay registered until its active agents can be checked.']:
    assert all(strings[key]['localizations'][lang]['stringUnit']['state'] == 'translated'
               and strings[key]['localizations'][lang]['stringUnit']['value'] for lang in ['ko', 'ja']), key

# 1. The service, in the app's language mode.
features = []
for feature in ['MemberImportVisibility', 'NonisolatedNonsendingByDefault', 'InferIsolatedConformances', 'DisableOutwardActorInference',
                'GlobalActorIsolatedTypesUsability', 'InferSendableFromCaptures']:
    features += ['-enable-upcoming-feature', feature]
swiftc = ['xcrun', 'swiftc', '-target', platform.machine() + '-apple-macos26.6.2', '-swift-version', '5', '-default-isolation', 'MainActor',
          *features, '-parse-as-library']
stage('service-build', 600, [*swiftc, *sources, '-o', str(out / 'app-service-tests')])
service_log = stage('service-tests', 180, [*sandboxed, str(out / 'app-service-tests'), str(out / 'run')])

# 2. The bundle, read.
bundle_log = stage('bundle-check', 60, [sys.executable, '-I', str(ROOT / 'Tests/AgentProxy/check-bundle.py'), '--app', str(app),
                                        '--configuration', 'Debug'])

# 3. The executable in the bundle, run where it is.
process_log = stage('bundled-process-tests', 240, [*sandboxed, sys.executable, '-I', str(ROOT / 'Tests/AgentProxy/process-tests.py'),
                                                   '--binary', str(executable), '--work', str(out / 'process')])


def call(sock, method):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(5); s.connect(str(sock))
        s.sendall((json.dumps({'id': '1', 'method': method, 'params': {}}) + '\n').encode())
        data = b''
        while not data.endswith(b'\n'):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    return json.loads(data)['result']


# "~/" is the user's home, as the Debug LaunchAgent gives it (the real Debug
# paths are too long for a socket under this folder).
tilde = out / 'tilde.py'
tilde.write_text(f'''import json, socket, subprocess, sys, time, hashlib
from pathlib import Path
home = Path({json.dumps(str(out / 'h'))})
sock = home / 'c.sock'
proc = subprocess.Popen([{json.dumps(str(executable))}, '--state-dir', '~/state', '--control-socket', '~/c.sock'],
                        stdin=subprocess.DEVNULL, stdout=open(home / 'proxy.log', 'wb'), stderr=subprocess.STDOUT)
try:
    deadline = time.monotonic() + 10
    while not sock.exists() and time.monotonic() < deadline: time.sleep(0.05)
    def call(method):
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(5); s.connect(str(sock))
            s.sendall((json.dumps({{'id': '1', 'method': method, 'params': {{}}}}) + '\\n').encode())
            data = b''
            while not data.endswith(b'\\n'):
                chunk = s.recv(65536)
                if not chunk: break
                data += chunk
        return json.loads(data)['result']
    status = call('proxy.status')
    assert (home / 'state/state.json').is_file(), 'the state folder is the home folder\\'s'
    assert status['build'] == hashlib.sha256(Path({json.dumps(str(executable))}).read_bytes()).hexdigest(), 'build is the bundled executable'
    deadline = time.monotonic() + 10
    while call('proxy.status')['recorder']['state'] != 'running' and time.monotonic() < deadline: time.sleep(0.1)
    assert call('proxy.status')['recorder']['state'] == 'running', 'its recorder, the same executable, runs'
    assert call('proxy.restartWhenIdle')['accepted'] is True
    assert proc.wait(timeout=10) == 0 and not sock.exists(), 'it exits once idle and removes its socket'
    print('PASS: "~/" paths are the home folder\\'s; build and recorder are the bundled executable')
finally:
    if proc.poll() is None: proc.kill(); proc.wait()
''')
tilde_log = stage('bundled-home-paths', 60, [*sandboxed, sys.executable, '-I', str(tilde)],
                  {'HOME': str(out / 'h'), 'CFFIXED_USER_HOME': str(out / 'h')})

assert hashes == {n: hashlib.sha256((ROOT / n).read_bytes()).hexdigest() for n in sorted(set(identity))}, 'sources changed during the run'
service_summary = service_log.strip().splitlines()[-1]
process = json.loads((out / 'process/results.json').read_text())
(out / 'validation.json').write_text(json.dumps({
    'passed': True, 'stages': records, 'service': service_summary, 'bundledProcessCases': process['passed'],
    'bundle': bundle_log.strip().splitlines()[-1], 'sandboxed': True, 'networkAccess': 'loopback and Unix sockets only',
    'smAppService': False, 'launchd': False, 'app': False, 'herdr': False, 'agents': False}, indent=2))
print(service_summary)
print(bundle_log.strip().splitlines()[-1])
print(f'bundled executable: {process["passed"]} process cases passed, {process["failed"]} failed')
print(tilde_log.strip().splitlines()[-1])
print('passed:', ', '.join(records))
