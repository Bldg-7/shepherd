#!/usr/bin/env python3
"""Pairing a Mac by QR code (SHPHRD-77), the iOS app's part, run on this Mac:
the device's PairingClient and the Scan Mac's QR Code sheet's PairingFlow,
end to end over 127.0.0.1 against the Mac app's own PairingCoordinator (its
owner's approval and SSH server probe stood in for, as in
run-mac-tests.py) and a made-up Mac — scanning, the request and the Mac's
answers, retries while the Mac's listener is busy, the wait for the answer,
the first connection after approval as a stand-in, a later scan of the same
Mac, and that a key turned down or never approved leaves nothing behind;
then, against the Citadel and swift-nio-ssh an app build made (--products),
the app's SSH check refusing an address out of its kind's range before it
connects anywhere.

No app, no Simulator, no camera, no SSH server (127.0.0.1:22 included), no
Keychain, no Secure Enclave, no LocalAuthentication, no DNS, no user
defaults, no real home folder. The device's connections are the app's own
Network framework ones, made to 127.0.0.1 in place of the address a code
resolved to. The test programs run under sandbox-exec with a profile that
lets them reach nothing but loopback and look no name up (mDNSResponder's
socket is denied); every listener they open is on 127.0.0.1.

Each stage runs in a process group of its own, which is ended if it outlasts
its time; nothing here lists or inspects other processes.

--products is the Build/Products/Debug folder of a macOS Debug build of the
Shepherd scheme, e.g. DerivedData/Build/Products/Debug."""
from pathlib import Path
import argparse, hashlib, json, os, platform, re, signal, subprocess

ROOT = Path(__file__).resolve().parents[2]
KIT = 'ShepherdKit/Sources/ShepherdKit'
APP = 'Shepherd/Pairing'
MOBILE = 'ShepherdMobile/Pairing'
p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
p.add_argument('--products', type=Path, required=True)
args = p.parse_args()
out = args.output.resolve()
out.mkdir(mode=0o700, parents=True, exist_ok=False)
for name in ['home', 'tmp', 'cache', 'device-output']:
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
# Both apps' language mode: Swift 5 with approachable concurrency and
# MainActor as the default isolation.
features = []
for feature in ['MemberImportVisibility', 'NonisolatedNonsendingByDefault', 'InferIsolatedConformances', 'DisableOutwardActorInference',
                'GlobalActorIsolatedTypesUsability', 'InferSendableFromCaptures']:
    features += ['-enable-upcoming-feature', feature]
swiftc = ['xcrun', 'swiftc', *target, '-swift-version', '5', '-default-isolation', 'MainActor', *features, '-parse-as-library']

kit_pairing = sorted(str(x.relative_to(ROOT)) for x in (ROOT / KIT / 'Pairing').glob('*.swift'))
kit = [f'{KIT}/Resources.swift', f'{KIT}/Machines/Machine.swift', f'{KIT}/Machines/MachineStore.swift', f'{KIT}/Machines/KeychainStore.swift',
       *kit_pairing, f'{KIT}/HerdrKit/Transport/SecureEnclaveSSHKey.swift', f'{KIT}/HerdrKit/Transport/ConnectionFailureDescription.swift']
# The Mac's pairing sources but the three that reach the system, as
# run-mac-tests.py takes them.
app_all = sorted(str(x.relative_to(ROOT)) for x in (ROOT / APP).glob('*.swift'))
system_only = [f'{APP}/LocalSSHServerProbe.swift', f'{APP}/PairingApproval.swift', f'{APP}/PairingCoordinator+System.swift']
assert all(name in app_all for name in system_only)
app = [name for name in app_all if name not in system_only]
fixtures = 'Tests/Pairing/PairingMacFixtures.swift'
# The iOS app's pairing sources that don't need iOS. The sheet and the
# scanner (SwiftUI, UIKit, AVFoundation) are only built for iOS, and the SSH
# check is in the Citadel stage below.
mobile_all = sorted(str(x.relative_to(ROOT)) for x in (ROOT / MOBILE).glob('*.swift'))
ios_only = [f'{MOBILE}/PairingSheet.swift', f'{MOBILE}/PairingScannerView.swift']
ssh_only = [f'{MOBILE}/SSHPairedMacChecker.swift']
assert all(name in mobile_all for name in ios_only + ssh_only)
mobile = [name for name in mobile_all if name not in ios_only + ssh_only]

# 1. The device against the Mac, on loopback.
device = kit + app + mobile + [fixtures, 'Tests/Pairing/PairingDeviceTests.swift']
stage('device-build', 600, [*swiftc, *device, '-o', str(out / 'pairing-device-tests')])
device_result = stage('device-tests', 300, [*sandboxed, str(out / 'pairing-device-tests'), str(out / 'device-output')])

# 2. The app's SSH check, with the Citadel and swift-nio-ssh an app build
# made, without connecting.
maps = sorted((derived / 'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'))
for base in [derived / 'SourcePackages/checkouts', ROOT / 'Vendor/Citadel', ROOT / 'Vendor/swift-nio-ssh']:
    maps += sorted(m for m in base.rglob('module.modulemap') if 'Benchmarks' not in m.parts)
objects = sorted(str(o) for o in products.glob('*.o') if o.name not in ('SwiftTerm.o', 'ShepherdKit.o'))
assert maps and any(o.endswith('/NIOSSH.o') for o in objects) and any(o.endswith('/Citadel.o') for o in objects), 'build the Shepherd scheme first'
transport = sorted(str(x.relative_to(ROOT)) for x in (ROOT / KIT / 'HerdrKit/Transport').glob('*.swift'))
models = sorted(str(x.relative_to(ROOT)) for x in (ROOT / KIT / 'HerdrKit/Models').glob('*.swift'))
ssh = [f'{KIT}/Resources.swift', f'{KIT}/Agents/AgentKind.swift', f'{KIT}/Machines/Machine.swift', f'{KIT}/Machines/MachineStore.swift',
       f'{KIT}/Machines/MachineStore+Transport.swift', f'{KIT}/Machines/KeychainStore.swift', *kit_pairing, *transport, *models,
       f'{KIT}/HerdrKit/HerdrClient.swift', f'{KIT}/HerdrKit/Terminal/HerdrExecutable.swift', f'{KIT}/HerdrKit/Terminal/ShellQuoting.swift',
       f'{KIT}/HerdrKit/Terminal/LocalCommand.swift', *mobile, *ssh_only, 'Tests/Pairing/PairingDeviceSSHTests.swift']
stage('ssh-build', 600, [*swiftc, '-I', str(products), *[a for m in maps for a in ('-Xcc', f'-fmodule-map-file={m}')], *ssh, *objects,
                         '-o', str(out / 'pairing-device-ssh-tests')])
ssh_result = stage('ssh-tests', 120, [*sandboxed, str(out / 'pairing-device-ssh-tests')])

# 3. Where it is wired in, and what the tests stay away from.
read = lambda n: (ROOT / n).read_text()
client = read(f'{MOBILE}/PairingClient.swift')
pair = client[client.index('    func pair('):client.index('    /// Sends the request and returns')]
assert pair.index('resolver.resolve(payload.address)') < pair.index('makeDeviceKey()') < pair.index('exchange(request')
assert pair.index('guard response.decision == .approved') < pair.index('store.addMachine(machine, privateKey: key.storedRepresentation)') \
    < pair.index('checker.check(machine, credential: key.storedRepresentation, at: address)'), 'saved only once approved, checked after'
assert 'nonisolated static let responseTimeout: Duration = .seconds(150)' in client
move = client[client.index('    func moveAddress('):client.index('enum PairingClientError')]
assert move.index('checker.check(moved') < move.index('guard check.succeeded') < move.index('store.updatePairedAddress(')
checker = read(f'{MOBILE}/SSHPairedMacChecker.swift')
for wired in ['pinnedFingerprint: machine.pinnedHostKeyFingerprint,', 'addressKind: machine.addressKind,',
              'addressResolver: PairingAddressResolver(resolver: ResolvedPairingName(address: address))', 'client.listPanes()']:
    assert wired in checker, wired
link = read(f'{MOBILE}/PairingLink.swift')
assert 'NWConnection(host: .ipv4(' in link and 'func open(_ address: PairingIPv4, port: UInt16)' in link
sheet = read(f'{MOBILE}/PairingSheet.swift')
assert 'PairingClient(resolver: PairingAddressResolver(), dialer: NetworkPairingDialer(),' in sheet
assert 'makeDeviceKey: { try SecureEnclaveSSHKey.makeForThisDevice() }, checker: SSHPairedMacChecker())' in sheet
machines = read('ShepherdMobile/MachinesView.swift')
assert 'Label("Scan Mac\'s QR Code", systemImage: "qrcode.viewfinder")' in machines and 'PairingSheet(machineStore: machineStore)' in machines
transport_source = read(f'{KIT}/HerdrKit/Transport/SSHHerdrTransport.swift')
assert 'catch SSHClientError.allAuthenticationOptionsFailed where usesPairedKey {' in transport_source
assert 'throw PairedConnectionError.accessRemoved' in transport_source
assert 'PairedConnectionError.accessRemoved:\n            return true' in read(f'{KIT}/Machines/MachineMonitor.swift')
plist = read('Config/Info-iOS.plist')
assert '<key>NSCameraUsageDescription</key>' in plist and '<key>NSLocalNetworkUsageDescription</key>' in plist
info_strings = json.loads(read('ShepherdMobile/InfoPlist.xcstrings'))['strings']
for key in ['NSCameraUsageDescription', 'NSLocalNetworkUsageDescription']:
    assert {'ko', 'ja'} <= set(info_strings[key]['localizations']), key
strings = json.loads(read('ShepherdMobile/Localizable.xcstrings'))['strings']
scan = strings["Scan Mac's QR Code"]['localizations']
assert scan['ko']['stringUnit']['value'] == 'Mac의 QR 코드 스캔' and scan['ja']['stringUnit']['value'] == 'Mac の QR コードをスキャン', \
    'the name the Mac tells people to tap'
untranslated = [k for k, v in strings.items() if not v.get('shouldTranslate', True) is False
                and not {'ko', 'ja'} <= set(v.get('localizations', {}))]
assert not untranslated, untranslated
for name in mobile_all:
    text = read(name)
    for forbidden in ['SecItem', 'LAContext', 'UIPasteboard', 'beginSheet', 'runModal', 'NSAlert', 'makeKeyAndOrderFront', 'orderFront']:
        assert forbidden not in text, (name, forbidden)
for name in ['Tests/Pairing/PairingDeviceTests.swift', 'Tests/Pairing/PairingDeviceSSHTests.swift']:
    text = read(name)
    for forbidden in ['UserDefaults.standard', 'UserDefaults(suiteName', 'removePersistentDomain', 'KeychainStore()', 'SecItem',
                      'makeInSecureEnclave', 'makeForThisDevice', 'SecureEnclave.P256', 'SystemPairingNameResolver', 'getaddrinfo',
                      'AVCapture', 'LAContext', 'NSPasteboard', 'UIPasteboard', 'PairingDefaults', 'NetworkPairingDialer()', '.live(',
                      '.system()', 'beginSheet', 'runModal', 'NSAlert', 'makeKey', 'orderFront', 'Process(', 'tailscale"']:
        assert forbidden not in text, (name, forbidden)
device_tests = read('Tests/Pairing/PairingDeviceTests.swift')
assert 'SSHPairedMacChecker' not in device_tests, 'the first connection is a stand-in in the device tests'
assert 'inner.open(PairingIPv4(127, 0, 0, 1), port: port)' in device_tests, 'every device connection goes to loopback'
stages.append('static-checks')

hashed = device + ssh + ios_only + ['Tests/Pairing/run-device-tests.py', 'ShepherdMobile/MachinesView.swift', 'Config/Info-iOS.plist',
                                    'ShepherdMobile/InfoPlist.xcstrings', 'ShepherdMobile/Localizable.xcstrings']
(out / 'source-hashes.json').write_text(json.dumps({n: hashlib.sha256((ROOT / n).read_bytes()).hexdigest() for n in sorted(set(hashed))}, indent=2))
summary = {'device': device_result.strip().splitlines()[-1], 'ssh': ssh_result.strip().splitlines()[-1]}
(out / 'validation.json').write_text(json.dumps({'passed': True, 'stages': stages, 'summary': summary, 'sandboxed': True,
                                                 'networkAccess': 'loopback only', 'listeners': '127.0.0.1 only', 'nameLookups': False,
                                                 'realSSH': False, 'keychain': False, 'secureEnclave': False, 'camera': False,
                                                 'localAuthentication': False, 'userDefaults': False, 'realHome': False, 'app': False,
                                                 'simulator': False}, indent=2))
print('device:', summary['device'])
print('ssh:', summary['ssh'])
print('passed:', ', '.join(stages))
