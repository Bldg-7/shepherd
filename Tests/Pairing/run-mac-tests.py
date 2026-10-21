#!/usr/bin/env python3
"""Pairing a Mac by QR code (SHPHRD-77), the Mac app's part: the address
selector from made-up networks, the Tailscale name lookups with a stand-in
resolver, the pairing listener's filter and limits, ~/.ssh/authorized_keys in
a temporary home folder (read back with ssh-keygen), the device list and
history in a temporary folder, the installation ID in memory, the QR code
read back with Core Image, the coordinator end to end with a device on
127.0.0.1, the SSH server probe's key exchange half against the Citadel and
swift-nio-ssh an app build made (--products), and Settings' iPhone and iPad
pages in never-shown windows, read and pressed through accessibility.

No app, no SSH server (127.0.0.1:22 included), no Keychain, no Secure
Enclave, no LocalAuthentication, no DNS, no System Settings, no pasteboard,
no user defaults, no real ~/.ssh. The test programs run under sandbox-exec
with a profile that lets them reach nothing but loopback and look no name up
(mDNSResponder's socket is denied); every listener they open is on
127.0.0.1.

Each stage runs in a process group of its own, which is ended if it outlasts
its time; nothing here lists or inspects other processes.

--products is the Build/Products/Debug folder of a macOS Debug build of the
Shepherd scheme, e.g. DerivedData/Build/Products/Debug."""
from pathlib import Path
import argparse, hashlib, json, os, platform, re, signal, subprocess

ROOT = Path(__file__).resolve().parents[2]
KIT = 'ShepherdKit/Sources/ShepherdKit'
APP = 'Shepherd/Pairing'
p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
p.add_argument('--products', type=Path, required=True)
args = p.parse_args()
out = args.output.resolve()
out.mkdir(mode=0o700, parents=True, exist_ok=False)
for name in ['home', 'tmp', 'cache', 'core-output', 'views-output']:
    (out / name).mkdir(mode=0o700)
products = args.products.resolve()
derived = products.parents[2]

env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer', HOME=str(out / 'home'),
           CFFIXED_USER_HOME=str(out / 'home'), TMPDIR=str(out / 'tmp'), CLANG_MODULE_CACHE_PATH=str(out / 'cache'))
stages = []


def stage(name, seconds, command):
    log = out / (name + '.log')
    with open(log, 'wb') as handle:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise SystemExit(f'{name}: timed out after {seconds}s\n' + log.read_text(errors='replace')[-4000:])
    if code != 0:
        raise SystemExit(f'{name}: exit {code}\n' + log.read_text(errors='replace')[-6000:])
    stages.append(name)
    return log.read_text(errors='replace')


# Loopback only, and no name lookups: getaddrinfo goes through mDNSResponder.
profile = out / 'tests.sb'
profile.write_text('(version 1)\n(allow default)\n(deny network-outbound)\n'
                   '(allow network-outbound (remote ip "localhost:*"))\n'
                   '(deny network-outbound (literal "/private/var/run/mDNSResponder"))\n')
sandboxed = ['sandbox-exec', '-f', str(profile)]

target = ['-target', platform.machine() + '-apple-macos26.6.2']
# The app target's language mode: Swift 5 with approachable concurrency and
# MainActor as the default isolation.
features = []
for feature in ['MemberImportVisibility', 'NonisolatedNonsendingByDefault', 'InferIsolatedConformances', 'DisableOutwardActorInference',
                'GlobalActorIsolatedTypesUsability', 'InferSendableFromCaptures']:
    features += ['-enable-upcoming-feature', feature]
swiftc = ['xcrun', 'swiftc', *target, '-swift-version', '5', '-default-isolation', 'MainActor', *features, '-parse-as-library']

kit_pairing = sorted(str(x.relative_to(ROOT)) for x in (ROOT / KIT / 'Pairing').glob('*.swift'))
kit = [f'{KIT}/Resources.swift', f'{KIT}/Machines/Machine.swift', *kit_pairing, f'{KIT}/HerdrKit/Transport/SecureEnclaveSSHKey.swift']
# The app's pairing sources but the three that reach the system: the SSH
# server probe (Citadel, its own stage below), Touch ID and the password
# (LocalAuthentication, never compiled here), and the app's environment.
app_all = sorted(str(x.relative_to(ROOT)) for x in (ROOT / APP).glob('*.swift'))
system_only = [f'{APP}/LocalSSHServerProbe.swift', f'{APP}/PairingApproval.swift', f'{APP}/PairingCoordinator+System.swift']
assert all(name in app_all for name in system_only)
app = [name for name in app_all if name not in system_only]
fixtures = 'Tests/Pairing/PairingMacFixtures.swift'

# 1. The pairing logic, with a device on loopback.
core = kit + app + [fixtures, 'Tests/Pairing/PairingMacTests.swift']
stage('core-build', 600, [*swiftc, *core, '-o', str(out / 'pairing-mac-tests')])
core_result = stage('core-tests', 240, [*sandboxed, str(out / 'pairing-mac-tests'), str(out / 'core-output')])

# The line the coordinator wrote, as OpenSSH reads it.
written = out / 'core-output/trip/.ssh/authorized_keys'
listed = subprocess.run(['ssh-keygen', '-l', '-E', 'sha256', '-f', str(written)], env=env, capture_output=True, text=True, check=True,
                        timeout=30).stdout.split()
assert listed[0] == '256' and listed[1].startswith('SHA256:') and listed[-1] == '(ECDSA)', listed
assert re.fullmatch(r'shepherd-mobile:[0-9a-f]{8}:minsu-s-iphone', listed[2]), listed
assert written.read_text().startswith('restrict,port-forwarding ecdsa-sha2-nistp256 ')
stages.append('ssh-keygen-reads-the-written-line')

# 2. The SSH server probe's half that goes through Citadel, without connecting.
maps = sorted((derived / 'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'))
for base in [derived / 'SourcePackages/checkouts', ROOT / 'Vendor/Citadel', ROOT / 'Vendor/swift-nio-ssh']:
    maps += sorted(m for m in base.rglob('module.modulemap') if 'Benchmarks' not in m.parts)
objects = sorted(str(o) for o in products.glob('*.o') if o.name not in ('SwiftTerm.o', 'ShepherdKit.o'))
assert maps and any(o.endswith('/NIOSSH.o') for o in objects) and any(o.endswith('/Citadel.o') for o in objects), 'build the Shepherd scheme first'
transport = sorted(str(x.relative_to(ROOT)) for x in (ROOT / KIT / 'HerdrKit/Transport').glob('*.swift'))
models = sorted(str(x.relative_to(ROOT)) for x in (ROOT / KIT / 'HerdrKit/Models').glob('*.swift'))
probe = [f'{KIT}/Resources.swift', f'{KIT}/Agents/AgentKind.swift', f'{KIT}/Machines/Machine.swift', f'{KIT}/Machines/MachineStore.swift',
         f'{KIT}/Machines/MachineStore+Transport.swift', f'{KIT}/Machines/KeychainStore.swift', *kit_pairing, *transport, *models,
         f'{KIT}/HerdrKit/Terminal/HerdrExecutable.swift', f'{KIT}/HerdrKit/Terminal/ShellQuoting.swift', f'{KIT}/HerdrKit/Terminal/LocalCommand.swift',
         f'{APP}/LocalSSHServerProbe.swift', f'{APP}/PairingPreflight.swift', 'Tests/Pairing/PairingProbeTests.swift']
stage('probe-build', 600, [*swiftc, '-I', str(products), *[a for m in maps for a in ('-Xcc', f'-fmodule-map-file={m}')], *probe, *objects,
                           '-o', str(out / 'pairing-probe-tests')])
probe_result = stage('probe-tests', 120, [*sandboxed, str(out / 'pairing-probe-tests')])

# 3. Settings' pages, in never-shown windows.
views = kit + app + ['Shepherd/Hosts/Views/SettingsPageChrome.swift', 'Shepherd/Hosts/Views/InfoButton.swift', 'Shepherd/Hosts/Views/PairDeviceView.swift',
                     'Shepherd/Hosts/Views/PairedDevicesSettingsView.swift', fixtures, 'Tests/Pairing/PairingSettingsViewTests.swift']
stage('views-build', 600, [*swiftc, *views, '-o', str(out / 'pairing-view-tests')])
views_result = stage('views-tests', 240, [*sandboxed, str(out / 'pairing-view-tests'), str(out / 'views-output')])

# 4. Where it is wired in, and what the tests stay away from.
read = lambda n: (ROOT / n).read_text()
settings = read('Shepherd/Hosts/Views/MachinesSettingsView.swift')
section = settings[settings.index('                Section {\n                    pageRow('):]
assert section.index('pageRow("iPhone and iPad", systemImage: "iphone")') < section.index('pageRow("Notifications"'), \
    'iPhone and iPad is the first row of the pages on Settings\' first page'
assert 'PairedDevicesSettingsView(model: .system(),' in settings and 'PairingCoordinator(environment: .system())' in settings
coordinator = read(f'{APP}/PairingCoordinator.swift')
assert 'var listenAddress: PairingListener.Address = .any' in coordinator and 'var ticks = true' in coordinator
assert 'static let codeLifetime: TimeInterval = 120' in coordinator and 'static let listenerLifetime: TimeInterval = 600' in coordinator
listener = read(f'{APP}/PairingListener.swift')
assert 'AF_INET6' not in listener and 'Darwin.socket(AF_INET, SOCK_STREAM, 0)' in listener and 'FD_CLOEXEC' in listener
assert '(address == .loopback ? INADDR_LOOPBACK : INADDR_ANY)' in listener
probe_source = read(f'{APP}/LocalSSHServerProbe.swift')
assert 'var host = "127.0.0.1"' in probe_source and 'var port = 22' in probe_source
assert '.custom(OfferNothing())' in probe_source and '.custom(HostKeyCapture(captured: captured))' in probe_source
for name in app_all + ['Shepherd/Hosts/Views/PairDeviceView.swift', 'Shepherd/Hosts/Views/PairedDevicesSettingsView.swift']:
    text = read(name)
    assert 'SecItem' not in text, name
    assert ('Process()' not in text) or name == f'{APP}/PairingPreflight.swift', name
    assert ('LAContext' not in text) or name == f'{APP}/PairingApproval.swift', name
    assert ('NSWorkspace.shared.open' not in text) or name == 'Shepherd/Hosts/Views/PairDeviceView.swift', name
    for forbidden in ['beginSheet', 'runModal', 'NSAlert', 'makeKeyAndOrderFront', 'orderFront']:
        assert forbidden not in text, (name, forbidden)
assert 'socketfilterfw' in read(f'{APP}/PairingPreflight.swift') and 'Services_RemoteLogin' in read(f'{APP}/PairingPreflight.swift')
tests = ['Tests/Pairing/PairingMacFixtures.swift', 'Tests/Pairing/PairingMacTests.swift', 'Tests/Pairing/PairingSettingsViewTests.swift',
         'Tests/Pairing/PairingProbeTests.swift']
for name in tests:
    text = read(name)
    for forbidden in ['LAContext', 'DeviceOwnerApproval', 'SystemTailscaleNameResolver', 'SystemPairingNameResolver', 'NetworkChangeWatcher',
                      '.system()', 'UserDefaults', 'NSPasteboard', 'NSWorkspace', 'FirewallStatusReader.current', 'LocalHerdrStatus',
                      'forThisAccount', 'PairedDeviceStore.standard', '.probe()', 'beginSheet', 'runModal', 'NSAlert', 'makeKey', 'orderFront',
                      'SecItem', 'KeychainStore()', 'SecureEnclave.P256', 'getaddrinfo', 'getnameinfo', '"tailscale"', 'Tailscale.app',
                      'bin/tailscale', 'Process(']:
        assert forbidden not in text, (name, forbidden)
assert 'environment.listenAddress = .loopback' in read(fixtures) and 'environment.watchesNetwork = false' in read(fixtures)
# Nothing pressed that would open System Settings, a dialog or the pasteboard.
pressed = re.findall(r'press\(([^\n]*)\)', read('Tests/Pairing/PairingSettingsViewTests.swift'))
assert pressed and not [p for p in pressed if re.search(r'remove|open-sharing|copy|Copy', p)], pressed
stages.append('static-checks')

hashed = core + probe + views + ['Tests/Pairing/run-mac-tests.py', 'Shepherd/Hosts/Views/MachinesSettingsView.swift'] + system_only
(out / 'source-hashes.json').write_text(json.dumps({n: hashlib.sha256((ROOT / n).read_bytes()).hexdigest() for n in sorted(set(hashed))}, indent=2))
summary = {'core': core_result.strip().splitlines()[-1], 'probe': probe_result.strip().splitlines()[-1], 'views': views_result.strip().splitlines()[-1]}
(out / 'validation.json').write_text(json.dumps({'passed': True, 'stages': stages, 'summary': summary, 'sandboxed': True,
                                                 'networkAccess': 'loopback only', 'listeners': '127.0.0.1 only', 'nameLookups': False,
                                                 'realSSH': False, 'keychain': False, 'secureEnclave': False, 'localAuthentication': False,
                                                 'userDefaults': False, 'realHome': False, 'app': False, 'windowsShown': False}, indent=2))
print('core:', summary['core'])
print('probe:', summary['probe'])
print('views:', summary['views'])
print('passed:', ', '.join(stages))
