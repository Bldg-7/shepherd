#!/usr/bin/env python3
"""Pairing a Mac by QR code (SHPHRD-77), the part ShepherdKit holds: address
kinds and ranges, the name lookup with a stand-in resolver, the QR code's
text, the HPKE messages and confirmation code, the authorized_keys line (read
back with ssh-keygen), the device key with a software P-256 key in the Secure
Enclave's place, Machine's JSON, and, against the Citadel and swift-nio-ssh an
app build made (--products), the key as swift-nio-ssh offers it, the QR code's
host key pin, and SSHHerdrTransport refusing a paired Mac's address that is
out of range before it connects anywhere.

No app, no SSH server, no Keychain, no Secure Enclave, no LocalAuthentication.
The test programs run under sandbox-exec with a profile that lets them reach
nothing but loopback and look no name up (mDNSResponder's socket is denied),
so a real lookup can't happen even by mistake; one of them listens on
127.0.0.1 to count connections that must not come.

Each stage runs in a process group of its own, which is ended if it outlasts
its time; nothing here lists or inspects other processes.

--products is the Build/Products/Debug folder of a macOS Debug build of the
Shepherd scheme, e.g. DerivedData/Build/Products/Debug."""
from pathlib import Path
import argparse, hashlib, json, os, platform, re, signal, subprocess

ROOT = Path(__file__).resolve().parents[2]
KIT = 'ShepherdKit/Sources/ShepherdKit'
p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
p.add_argument('--products', type=Path, required=True)
args = p.parse_args()
out = args.output.resolve()
out.mkdir(mode=0o700, parents=True, exist_ok=False)
for name in ['home', 'tmp', 'cache', 'core-output']:
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

pairing = sorted(str(x.relative_to(ROOT)) for x in (ROOT / KIT / 'Pairing').glob('*.swift'))
target = ['-target', platform.machine() + '-apple-macos26.6.2']

# 1. Without Citadel: what both apps share before a connection.
core = [f'{KIT}/Resources.swift', f'{KIT}/Machines/Machine.swift', *pairing, f'{KIT}/HerdrKit/Transport/SecureEnclaveSSHKey.swift',
        'Tests/Pairing/PairingCoreTests.swift']
stage('core-build', 300, ['xcrun', 'swiftc', *target, '-swift-version', '6', '-default-isolation', 'MainActor', '-parse-as-library',
                          *core, '-o', str(out / 'pairing-core-tests')])
core_result = stage('core-tests', 120, [*sandboxed, str(out / 'pairing-core-tests'), str(out / 'core-output')])

# The authorized_keys line as OpenSSH reads it: options, key and comment, and
# the same fingerprint (ssh-keygen leaves base64's padding off).
listed = subprocess.run(['ssh-keygen', '-l', '-E', 'sha256', '-f', str(out / 'core-output/authorized_keys')], env=env,
                        capture_output=True, text=True, check=True, timeout=30).stdout.split()
fingerprint = (out / 'core-output/fingerprint').read_text().strip()
assert listed[0] == '256' and listed[1] == fingerprint.rstrip('=') and listed[-1] == '(ECDSA)', listed
assert listed[2] == 'shepherd-mobile:0f1e2d3c:minsu-s-iphone-15', listed
stages.append('ssh-keygen-reads-the-line')

# 2. With the Citadel and swift-nio-ssh an app build made, in the package's
# own language mode (Swift 5 with its upcoming features), since the
# transport's sources are written against it.
maps = sorted((derived / 'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'))
for base in [derived / 'SourcePackages/checkouts', ROOT / 'Vendor/Citadel', ROOT / 'Vendor/swift-nio-ssh']:
    maps += sorted(m for m in base.rglob('module.modulemap') if 'Benchmarks' not in m.parts)
objects = sorted(str(o) for o in products.glob('*.o') if o.name not in ('SwiftTerm.o', 'ShepherdKit.o'))
assert maps and any(o.endswith('/NIOSSH.o') for o in objects) and any(o.endswith('/Citadel.o') for o in objects), 'build the Shepherd scheme first'
features = []
for feature in ['MemberImportVisibility', 'NonisolatedNonsendingByDefault', 'InferIsolatedConformances', 'DisableOutwardActorInference',
                'GlobalActorIsolatedTypesUsability', 'InferSendableFromCaptures']:
    features += ['-enable-upcoming-feature', feature]
transport = sorted(str(x.relative_to(ROOT)) for x in (ROOT / KIT / 'HerdrKit/Transport').glob('*.swift'))
models = sorted(str(x.relative_to(ROOT)) for x in (ROOT / KIT / 'HerdrKit/Models').glob('*.swift'))
ssh = [f'{KIT}/Resources.swift', f'{KIT}/Agents/AgentKind.swift', f'{KIT}/Machines/Machine.swift', f'{KIT}/Machines/MachineStore.swift',
       f'{KIT}/Machines/MachineStore+Transport.swift', f'{KIT}/Machines/KeychainStore.swift', *pairing, *transport, *models,
       f'{KIT}/HerdrKit/Terminal/HerdrExecutable.swift', f'{KIT}/HerdrKit/Terminal/ShellQuoting.swift', f'{KIT}/HerdrKit/Terminal/LocalCommand.swift',
       'Tests/Pairing/PairingSSHTests.swift']
stage('ssh-build', 600, ['xcrun', 'swiftc', *target, '-swift-version', '5', '-default-isolation', 'MainActor', *features, '-parse-as-library',
                         '-I', str(products), *[a for m in maps for a in ('-Xcc', f'-fmodule-map-file={m}')], *ssh, *objects,
                         '-o', str(out / 'pairing-ssh-tests')])
ssh_result = stage('ssh-tests', 120, [*sandboxed, str(out / 'pairing-ssh-tests')])

# 3. Where it is wired in, and what the tests stay away from.
read = lambda n: (ROOT / n).read_text()
transport_source = read(f'{KIT}/HerdrKit/Transport/SSHHerdrTransport.swift')
connect = transport_source[transport_source.index('public func connect() async throws {'):transport_source.index('private func resolveRemoteHome')]
assert connect.index('addressResolver.resolve(hostname: host, kind: addressKind)') < connect.index('credential.authenticationMethod') < connect.index('SSHClient.connect(')
assert 'host: connectionHost,' in connect and 'host: host,' not in connect
assert 'catch is HostKeyValidationError where addressKind?.isLAN == true' in connect
assert 'addressKind: current.addressKind' in read(f'{KIT}/Machines/MachineStore+Transport.swift')
assert 'case .secureEnclaveKey(let stored):' in read(f'{KIT}/HerdrKit/Transport/HostCredential.swift')
for name in pairing + [f'{KIT}/HerdrKit/Transport/SecureEnclaveSSHKey.swift']:
    text = read(name)
    assert 'SecItem' not in text and 'LAContext(' not in text and 'evaluatePolicy' not in text, name
for name in ['Tests/Pairing/PairingCoreTests.swift', 'Tests/Pairing/PairingSSHTests.swift']:
    text = read(name)
    assert 'makeInSecureEnclave' not in text and 'makeForThisDevice' not in text and 'SecureEnclave.P256' not in text, name
    assert 'SystemPairingNameResolver' not in text and 'KeychainStore()' not in text, name
stages.append('static-checks')

hashed = core + ssh + ['Tests/Pairing/run-tests.py']
(out / 'source-hashes.json').write_text(json.dumps({n: hashlib.sha256((ROOT / n).read_bytes()).hexdigest() for n in sorted(set(hashed))}, indent=2))
summary = {'core': core_result.strip().splitlines()[-1], 'ssh': ssh_result.strip().splitlines()[-1]}
(out / 'validation.json').write_text(json.dumps({'passed': True, 'stages': stages, 'summary': summary, 'sandboxed': True,
                                                 'networkAccess': 'loopback only', 'nameLookups': False, 'realSSH': False,
                                                 'keychain': False, 'secureEnclave': False, 'app': False}, indent=2))
print('core:', summary['core'])
print('ssh:', summary['ssh'])
print('passed:', ', '.join(stages))
