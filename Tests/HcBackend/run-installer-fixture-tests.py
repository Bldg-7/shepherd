#!/usr/bin/env python3
"""Official installer snapshot against a file:// mirror in a private HOME.
A constrained mktemp wrapper keeps all installer scratch files inside this root.
No native-default-temp, HTTP/TLS-delivery, update, launchd or release qualification.
Never invokes an installer against the user's installation or service domain.
"""
from pathlib import Path
import argparse, hashlib, json, os, platform, shutil, socket, subprocess, sys, time
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'Tests/CoreProtocol'))
import core_test_artifact as artifacts
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--installer', type=Path, required=True)
p.add_argument('--installer-sha256', required=True)
p.add_argument('--official-017-archive', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
out = a.output.resolve()
out.mkdir(mode=0o700, parents=True, exist_ok=False)
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
assert len(a.installer_sha256) == 64 and sha(a.installer) == a.installer_sha256, 'installer snapshot hash mismatch'
installer = out/'install.sh'
shutil.copyfile(a.installer, installer)
archive = out/'official.tar.gz'
shutil.copyfile(a.official_017_archive, archive)
reference = out/'reference-core'
provenance = artifacts.extract(artifacts.select(official_017_archive=archive), reference)
expected_binary = sha(reference)
(out/'provenance.json').write_text(json.dumps({'artifact':provenance,'installerSHA256':sha(installer),
    'installerSource':'https://releases.herdr.dev/core/install.sh','fileMirrorOnly':True,
    'mktempAdaptation':'PATH wrapper supplies an explicit owned template; real macOS mktemp ignores TMPDIR for bare -d'}, indent=2))
# Child processes cannot access the real home, write outside this owned root,
# contact any network peer, or execute the tools that change launchd/TCC state.
profile = out/'private.sb'
profile.write_text('(version 1)\n(allow default)\n(deny network*)\n(deny file-write*)\n'
    '(allow file-write* (subpath '+json.dumps(str(out))+') (literal "/dev/null"))\n'
    '(deny file-read* (subpath '+json.dumps(str(Path.home()))+'))\n'
    '(deny process-exec (literal "/bin/launchctl") (literal "/usr/bin/launchctl") '
    '(literal "/usr/bin/find") (literal "/usr/bin/osascript") (literal "/usr/bin/security"))\n')
sandbox = ['/usr/bin/sandbox-exec','-f',str(profile)]
checks = []
def check(ok, label):
    assert ok, label
    checks.append(label)
def case(name, *, collision=False, bad_checksum=False):
    root = out/name
    for leaf in ['home','tmp','state','config','run','bin','mirror/core/0.1.17']:
        (root/leaf).mkdir(mode=0o700, parents=True, exist_ok=True)
    # Darwin mktemp -d without a template uses the account's system temp
    # directory, even with this TMPDIR. Do not grant writes there: a disclosed
    # fixture wrapper supplies an explicit template to the actual system tool.
    (root/'bin/mktemp').write_text('#!/bin/sh\n[ "$#" -eq 1 ] && [ "$1" = -d ] || exit 64\nexec /usr/bin/mktemp -d "$TMPDIR/installer.XXXXXXXX"\n')
    (root/'bin/mktemp').chmod(0o700)
    target = 'macos-aarch64' if platform.machine() == 'arm64' else 'macos-x86_64'
    manifest = {'version':'0.1.17','targets':{target:{'url':archive.as_uri(),
        'sha256':'0'*64 if bad_checksum else sha(archive)}}}
    (root/'mirror/core/0.1.17/manifest.json').write_text(json.dumps(manifest))
    alias = root/'bin/hc'
    original_alias = b'#!/bin/sh\nprintf "owned other hc; must not be executed by the installer\\n"\n'
    if collision:
        alias.write_bytes(original_alias); alias.chmod(0o700)
    env = {'PATH':str(root/'bin')+':/usr/bin:/bin:/usr/sbin:/sbin', 'HOME':str(root/'home'),
        'TMPDIR':str(root/'tmp'), 'XDG_STATE_HOME':str(root/'state'), 'XDG_CONFIG_HOME':str(root/'config'),
        'XDG_RUNTIME_DIR':str(root/'run'), 'HC_SESSION':'owned', 'HC_SOCKET':str(root/'run/owned.sock'),
        'SSH_CONNECTION':'owned-fixture-no-launchd', 'LANG':'en_US.UTF-8','DO_NOT_TRACK':'1',
        'HERDR_RELEASES_URL':(root/'mirror').as_uri(), 'HC_INSTALL_DIR':str(root/'bin'), 'HC_VERSION':'0.1.17'}
    return root, env, alias, original_alias

def run(name, env, command, expected=0):
    start = time.monotonic()
    result = subprocess.run(sandbox+command, env=env, cwd=out, capture_output=True, timeout=30)
    (out/(name+'.stdout.log')).write_bytes(result.stdout)
    (out/(name+'.stderr.log')).write_bytes(result.stderr)
    (out/(name+'.stage.json')).write_text(json.dumps({'exitCode':result.returncode,'seconds':time.monotonic()-start}))
    check(result.returncode == expected if expected is not None else result.returncode != 0, name+' exit')
    return result

root, env, alias, _ = case('fresh')
# An owned loopback listener distinguishes sandbox denial from connection refusal.
with socket.socket() as listener:
    listener.bind(('127.0.0.1',0)); listener.listen(1)
    probe = 'import socket,sys,errno\ntry:socket.create_connection(("127.0.0.1",int(sys.argv[1])))\nexcept OSError as e:sys.exit(0 if e.errno in (errno.EPERM,errno.EACCES) else 2)\nsys.exit(1)'
    run('network-canary',env,['/usr/bin/python3','-I','-S','-c',probe,str(listener.getsockname()[1])])
run('fresh-install',env,['/bin/sh',str(installer)])
check(sha(root/'bin/herdr-core') == expected_binary,'fresh installed binary exact official hash')
check(alias.is_symlink() and os.readlink(alias) == 'herdr-core','fresh hc alias is relative to owned install')
check('0.1.17' in run('fresh-version',env,[str(alias),'--version']).stdout.decode(),'installed alias reports selected version')
check(not list((root/'tmp').iterdir()),'installer temporary directory retired')
check(not (root/'run/owned.sock').exists(),'fresh installer did not start a core')

root, env, alias, original_alias = case('name-collision',collision=True)
run('name-collision-install',env,['/bin/sh',str(installer)])
check(not alias.is_symlink() and alias.read_bytes() == original_alias,'unrelated owned hc command preserved byte-for-byte')
check(sha(root/'bin/herdr-core') == expected_binary,'core still installs when hc name belongs to another program')

root, env, alias, _ = case('bad-checksum',bad_checksum=True)
result = run('bad-checksum-install',env,['/bin/sh',str(installer)],expected=None)
check(b'checksum mismatch' in result.stderr,'damaged download explicitly rejected')
check(not (root/'bin/herdr-core').exists() and not alias.exists(),'checksum failure creates no install or alias')
check(not list((root/'tmp').iterdir()),'checksum failure retires its temporary directory')

(out/'validation.json').write_text(json.dumps({'passed':True,'checks':checks,'officialCore':'0.1.17',
    'privateHOME':True,'networkDenied':True,'fileMirrorOnly':True,'explicitOwnedMktempTemplate':True,
    'nativeDefaultTempQualified':False,'userInstallationTouched':False,
    'existingInstallUpdateQualified':False,'productionLaunchdQualified':False,'releaseCutover':False},indent=2))
print('PASS private official installer fixtures: '+str(out),flush=True)
