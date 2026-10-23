#!/usr/bin/env python3
"""The agent proxy (AgentProxy/) built offline from the app's resolved
packages and tested without the app, an agent, launchd or the network.

  run-forwarder-tests.py --output <new folder> --dependencies build/SourcePackages/checkouts

1. The package's own manifest is read (`swift package dump-package`), and a
   package of the same targets, with the dependencies taken from the
   checkouts folder by path, is made under the output folder with the test
   program beside them.
2. ForwarderTests runs the forwarder in process through its test initializer:
   fake TLS upstreams on 127.0.0.1 with certificates from a test authority,
   the real executable's recorder, and every state folder and socket under the
   output folder.
3. process-tests.py runs the built executable itself the way launchd would,
   sending its listener only requests it must refuse before connecting.
4. The secrets the tests sent (credential headers with marker strings, and the
   route tokens) are looked for in every file the run left, outside the copied
   sources: state folders, recorder copies, logs and answers.

Both test stages run under sandbox-exec with no outgoing connection allowed
but to 127.0.0.1 and none to the system's name resolver.
"""
import argparse, hashlib, json, os, re, shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
p.add_argument('--dependencies', type=Path, required=True,
               help='folder holding swift-nio, swift-nio-ssl, swift-crypto, swift-certificates and their siblings')
a = p.parse_args()
out = a.output.resolve(); out.mkdir(parents=True, exist_ok=False)
deps = a.dependencies.resolve()
for name in ['home', 'tmp', 'cache', 'package/Sources', 'fixtures']:
    (out / name).mkdir(parents=True, mode=0o700)
env = dict(os.environ, HOME=str(out / 'home'), CFFIXED_USER_HOME=str(out / 'home'), TMPDIR=str(out / 'tmp'),
           CLANG_MODULE_CACHE_PATH=str(out / 'cache'), DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
           SWIFTCI_USE_LOCAL_DEPS='1')

package_sources = sorted(p for p in (ROOT / 'AgentProxy/Sources').rglob('*') if p.is_file())
test_sources = sorted((ROOT / 'Tests/AgentProxy').glob('*.swift'))
identity = (['AgentProxy/Package.swift'] + [str(f.relative_to(ROOT)) for f in package_sources + test_sources]
            + ['Tests/AgentProxy/process-tests.py', 'Tests/AgentProxy/run-forwarder-tests.py'])
identity += ['Shepherd/ThirdPartyNotices.txt']
hashes = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in identity}
vendor = ROOT / 'AgentProxy/Sources/AgentProxyCompressionC/vendor'
provenance = json.loads((vendor / 'SOURCE.json').read_text())
assert provenance['archiveSHA256'] == '37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3'
assert all(hashlib.sha256((vendor / name).read_bytes()).hexdigest() == value for name, value in provenance['files'].items())
notices = (ROOT / 'Shepherd/ThirdPartyNotices.txt').read_text()
assert (vendor / 'LICENSE').read_text() in notices
assert 'Copyright (c) Yann Collet - Meta Platforms, Inc' in notices and 'Copyright (c) 2016 Tino Reichardt' in notices
(out / 'source-hashes.json').write_text(json.dumps(hashes, indent=2))

# The package's own manifest, read without resolving anything.
dump = subprocess.run(['/usr/bin/xcrun', 'swift', 'package', '--package-path', str(ROOT / 'AgentProxy'),
                       '--scratch-path', str(out / 'manifest-scratch'), 'dump-package'],
                      cwd=ROOT, env=env, capture_output=True, timeout=300)
(out / 'manifest.log').write_text(re.sub(r'compiled with: \[[^\]]*\]', 'compiled with: [...]', dump.stderr.decode(errors='replace')))
assert dump.returncode == 0, 'AgentProxy/Package.swift could not be read; see manifest.log'
manifest = json.loads(dump.stdout)
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2))
assert [(x['platformName'], x['version']) for x in manifest['platforms']] == [('macos', '26.6'), ('ios', '17.0')], 'platforms'
assert manifest.get('swiftLanguageVersions') == ['5'], 'Swift 5 language mode'
pins = {d['sourceControl'][0]['identity']: d['sourceControl'][0]['requirement']['range'][0]['lowerBound']
        for d in manifest['dependencies']}
assert pins == {'swift-nio': '2.103.0', 'swift-nio-ssl': '2.36.0', 'swift-crypto': '3.12.3'}, f'dependencies: {pins}'
products = {x['name']: x['targets'] for x in manifest['products']}
assert products == {'AgentProxyProtocol': ['AgentProxyProtocol'], 'AgentProxyCore': ['AgentProxyCore'],
                    'AgentProxyForwarder': ['AgentProxyForwarder'],
                    'hrdrhrdrhrdr-agent-proxy': ['AgentProxyTool']}, f'products: {products}'


def swift_dependency(item):
    if 'byName' in item:
        return json.dumps(item['byName'][0])
    if 'product' in item:
        return '.product(name: %s, package: %s)' % (json.dumps(item['product'][0]), json.dumps(item['product'][1]))
    if 'target' in item:
        return json.dumps(item['target'][0])
    raise AssertionError('unknown dependency form')


targets = []
for target in manifest['targets']:
    assert target['type'] in ('regular', 'executable')
    extra = ''
    if target['name'] == 'AgentProxyCompressionC':
        expected = [('c', 'define', 'ZSTD_DISABLE_ASM=1'), ('c', 'define', 'ZSTD_LEGACY_SUPPORT=0'),
                    ('c', 'define', 'XXH_NAMESPACE=ZSTD_'), ('linker', 'linkedLibrary', 'z')]
        actual = [(s['tool'], next(iter(s['kind'])), next(iter(s['kind'].values()))['_0']) for s in target['settings']]
        assert actual == expected, actual
        assert target['exclude'] == ['vendor/LICENSE', 'vendor/SOURCE.json']
        extra = ', exclude: ["vendor/LICENSE", "vendor/SOURCE.json"], cSettings: [.define("ZSTD_DISABLE_ASM", to: "1"), .define("ZSTD_LEGACY_SUPPORT", to: "0"), .define("XXH_NAMESPACE", to: "ZSTD_")], linkerSettings: [.linkedLibrary("z")]'
    else:
        assert not target.get('settings') and not target.get('exclude'), 'plain Swift targets only'
    kind = '.executableTarget' if target['type'] == 'executable' else '.target'
    targets.append('%s(name: %s, dependencies: [%s]%s)' % (kind, json.dumps(target['name']),
                         ', '.join(swift_dependency(d) for d in target['dependencies']), extra))
    source = ROOT / 'AgentProxy/Sources' / target['name']
    shutil.copytree(source, out / 'package/Sources' / target['name'])
assert {t['name'] for t in manifest['targets']} == {'AgentProxyProtocol', 'AgentProxyCore', 'AgentProxyCompressionC', 'AgentProxyForwarder', 'AgentProxyTool'}
(out / 'package/Sources/ForwarderTests').mkdir()
for source in test_sources:
    shutil.copy2(source, out / 'package/Sources/ForwarderTests' / source.name)
targets.append('.executableTarget(name: "ForwarderTests", dependencies: ["AgentProxyForwarder", "AgentProxyProtocol", "AgentProxyCore", '
               + ', '.join('.product(name: "%s", package: "%s")' % pair for pair in [
                   ('NIOCore', 'swift-nio'), ('NIOPosix', 'swift-nio'), ('NIOTLS', 'swift-nio'), ('NIOSSL', 'swift-nio-ssl'),
                   ('Crypto', 'swift-crypto'), ('X509', 'swift-certificates'), ('SwiftASN1', 'swift-asn1')]) + '])')
for name in ['swift-nio', 'swift-nio-ssl', 'swift-crypto', 'swift-certificates', 'swift-asn1']:
    assert (deps / name / 'Package.swift').is_file(), f'{name} is not in {deps}'
(out / 'package/Package.swift').write_text('''// swift-tools-version: 6.2
// Made by Tests/AgentProxy/run-forwarder-tests.py from AgentProxy/Package.swift.
import PackageDescription
let package = Package(name: "AgentProxyTests", platforms: [.macOS("26.6")], products: [
    %s
], dependencies: [
%s
], targets: [
    %s
], swiftLanguageModes: [.v5])
''' % (',\n    '.join('.%s(name: %s, targets: %s)' % ('executable' if 'executable' in x['type'] else 'library',
                                                           json.dumps(x['name']), json.dumps(x['targets']))
                       for x in manifest['products']),
       ',\n'.join('    .package(path: %s)' % json.dumps(str(deps / name))
                  for name in ['swift-nio', 'swift-nio-ssl', 'swift-crypto', 'swift-certificates', 'swift-asn1']),
       ',\n    '.join(targets)))

# A synthetic Codex request: forwarding keeps bytes unchanged; the recorder
# alone decodes its copy. Fixtures also exercise gzip, zlib and decoder bounds.
body = json.dumps({'model': 'gpt-5', 'stream': True, 'client_metadata': {'x-codex-turn-metadata': json.dumps({'request_kind': 'turn', 'thread_id': 'native'})}, 'input': [{'role': 'user', 'content': [
    {'type': 'input_text', 'text': ' '.join(hashlib.sha256(str(i).encode()).hexdigest()[:i % 9 + 2] for i in range(20000))}]}]}).encode()
try:
    from compression import zstd
    fixture = zstd.compress(body, level=3)
    assert zstd.decompress(fixture) == body
except ImportError:
    # A frame of raw blocks: valid zstd without a compressor.
    fixture = bytearray(b'\x28\xb5\x2f\xfd\xe0') + len(body).to_bytes(8, 'little')
    for offset in range(0, len(body), 1 << 17):
        block = body[offset:offset + (1 << 17)]
        last = 1 if offset + len(block) >= len(body) else 0
        fixture += (last | (len(block) << 3)).to_bytes(3, 'little') + block
    fixture = bytes(fixture)
(out / 'fixtures/codex-request.zst').write_bytes(fixture)
(out / 'fixtures/codex-request.json').write_bytes(body)
import gzip, zlib
(out / 'fixtures/codex-request.gz').write_bytes(gzip.compress(body, mtime=0))
(out / 'fixtures/codex-request.zz').write_bytes(zlib.compress(body))
response = b''.join(b'data: ' + json.dumps(event).encode() + b'\n\n' for event in [
    {'type': 'response.created', 'response': {'id': 'response'}},
    {'type': 'response.completed', 'response': {'id': 'response', 'status': 'completed', 'output': [
        {'id': 'answer', 'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'captured response'}]}]}}])
(out / 'fixtures/capture-response.gz').write_bytes(gzip.compress(response, mtime=0))
(out / 'fixtures/capture-response.zz').write_bytes(zlib.compress(response))
try:
    response_zst = zstd.compress(response, level=3)
except NameError:
    response_zst = b'\x28\xb5\x2f\xfd\xe0' + len(response).to_bytes(8, 'little') + (1 | len(response) << 3).to_bytes(3, 'little') + response
(out / 'fixtures/capture-response.zst').write_bytes(response_zst)
(out / 'sandbox.sb').write_text('''(version 1)
(allow default)
(deny network-outbound)
(allow network-outbound (remote ip "localhost:*"))
(allow network-outbound (remote unix-socket))
(deny network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))
''')

records = []
def stage(name, seconds, command):
    log = out / (name + '.log')
    code = subprocess.run([sys.executable, str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'), '--timeout', str(seconds),
                           '--natural-exit-grace', '15', '--log', str(log), '--', *command],
                          cwd=ROOT, env=env, timeout=seconds + 50).returncode
    record = json.loads(log.with_suffix('.stage.json').read_text()); records.append(record)
    (out / 'stages.json').write_text(json.dumps(records, indent=2))
    if code or not record['naturalExitConfirmed'] or record['signalsSent'] or not record['cleanupVerified']:
        raise RuntimeError(name + ' failed; see its log')

build = out / 'package/.build/debug'
sandbox = ['/usr/bin/sandbox-exec', '-f', str(out / 'sandbox.sb')]
stage('agent-proxy-build', 900, ['/usr/bin/xcrun', 'swift', 'build', '--package-path', str(out / 'package'), '--jobs', '4',
                                 '--disable-automatic-resolution'])
linkage = subprocess.check_output(['/usr/bin/otool', '-L', str(build / 'hrdrhrdrhrdr-agent-proxy')], text=True, timeout=30)
(out / 'compression-linkage.log').write_text(linkage)
assert '/opt/homebrew/' not in linkage and 'libzstd' not in linkage, 'decoder must not depend on a local zstd dylib'
stage('forwarder-tests', 300, sandbox + [str(build / 'ForwarderTests'), 'run', str(out / 'run'),
                                         str(build / 'hrdrhrdrhrdr-agent-proxy'), str(out / 'fixtures/codex-request.zst')])
stage('process-tests', 180, sandbox + [sys.executable, '-I', str(ROOT / 'Tests/AgentProxy/process-tests.py'),
                                       '--binary', str(build / 'hrdrhrdrhrdr-agent-proxy'), '--work', str(out / 'process')])

# Every secret the tests sent, in every file the run left but the copied
# sources and the lists of secrets themselves.
needle_files = [out / 'run/needles.json', out / 'process/needles.json']
needles = [n.encode() for f in needle_files for n in json.loads(f.read_text())]
assert len(needles) >= 8, 'the tests listed their secrets'
scanned = 0
for path in sorted(out.rglob('*')):
    if not path.is_file() or path.is_symlink() or path in needle_files or (out / 'package') in path.parents:
        continue
    data = path.read_bytes()
    scanned += 1
    for needle in needles:
        assert needle not in data, f'a secret the tests sent was found in {path.relative_to(out)}'

assert hashes == {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in identity}, 'source changed during validation'
forwarder = json.loads((out / 'run/results.json').read_text())
process = json.loads((out / 'process/results.json').read_text())
(out / 'validation.json').write_text(json.dumps({
    'passed': forwarder['failed'] == 0 and process['failed'] == 0,
    'forwarderCases': forwarder['passed'], 'processCases': process['passed'],
    'compressionCases': json.loads((out / 'fixtures/compression-results.json').read_text())['passed'],
    'filesScannedForSecrets': scanned, 'stages': len(records),
    'loopbackOnlySandbox': True, 'actualApp': 'NOTRUN', 'actualAgents': 'NOTRUN', 'launchd': 'NOTRUN'}, indent=2))
print(f'agent proxy: {forwarder["passed"]} forwarder cases and {process["passed"]} process cases passed; '
      f'{scanned} files held none of the secrets sent')
