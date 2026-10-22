#!/usr/bin/env python3
"""Adding, checking again and removing herdr machines (SHPHRD-83): OpenSSH's
and herdr's messages from fixtures, the host step wrapper and the known_hosts
append under /bin/sh, and the whole flow through the real LocalHerdrTransport
with a fake ssh on PATH and a fake herdr in a HOME of the test's own. Host
keys are made here with ssh-keygen, and their fingerprints read with
`ssh-keygen -lf`, to check the app's against. No network, no SSH server, no
real ~/.ssh, herdr state, Keychain or app.

And adding one only while the window shows This Mac (SHPHRD-110): the rule,
the launcher's row it makes and the menus' item as AppKit gets it from
SwiftUI, in a menu that is never opened; and in the sources, where the File
menu, the host group header's menu, the launcher and the panel take it.

Each stage runs in a process group of its own, which is ended if it outlasts
its time; nothing here lists or inspects other processes."""
from pathlib import Path
import argparse, hashlib, json, os, platform, shutil, signal, subprocess, sys

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT / 'Tests/HerdrMachineSetup'
p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
args = p.parse_args()
out = args.output.resolve()
out.mkdir(mode=0o700, parents=True, exist_ok=False)
for name in ['home', 'tmp', 'cache', 'bin', 'fake', 'keys']:
    (out / name).mkdir(mode=0o700)
home, fake, bin_dir, keys = out / 'home', out / 'fake', out / 'bin', out / 'keys'

env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer', HOME=str(home),
           CFFIXED_USER_HOME=str(home), TMPDIR=str(out / 'tmp'), CLANG_MODULE_CACHE_PATH=str(out / 'cache'))
stages = []


def stage(name, seconds, command, extra_env=None):
    log = out / (name + '.log')
    with open(log, 'wb') as handle:
        process = subprocess.Popen(command, cwd=ROOT, env=dict(env, **(extra_env or {})), stdout=handle,
                                   stderr=subprocess.STDOUT, start_new_session=True)
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


# The fakes: ssh on PATH, herdr where herdr's installer puts it, and a herdr
# on the far side of the fake ssh that only says its version.
shutil.copyfile(HERE / 'fake-ssh', bin_dir / 'ssh')
(bin_dir / 'ssh').chmod(0o755)
(home / '.local/bin').mkdir(parents=True)
shutil.copyfile(HERE / 'fake-herdr', home / '.local/bin/herdr')
(home / '.local/bin/herdr').chmod(0o755)
remote = fake / 'remote-home/.local/bin'
remote.mkdir(parents=True)
(remote / 'herdr').write_text('#!/bin/sh\n[ "$1 $2 $3" = "status client --json" ] && printf \'{"version":"0.9.1","channel":"stable"}\\n\' && exit 0\nexit 64\n')
(remote / 'herdr').chmod(0o755)

# Host keys of each kind, and what ssh-keygen says their fingerprints are.
fingerprints = []
for kind, label in [('ed25519', 'ED25519'), ('ecdsa', 'ECDSA'), ('rsa', 'RSA')]:
    key = keys / kind
    subprocess.run(['ssh-keygen', '-q', '-t', kind, '-N', '', '-C', '', '-f', str(key)], check=True, env=env)
    public = ' '.join(key.with_suffix('.pub').read_text().split()[:2])
    line = f'workbox.example {public}'
    known = keys / (kind + '.known_hosts')
    known.write_text(line + '\n')
    listed = subprocess.run(['ssh-keygen', '-l', '-E', 'sha256', '-f', str(known)], check=True, env=env,
                            capture_output=True, text=True).stdout.split()
    assert listed[1].startswith('SHA256:') and listed[-1] == f'({label})', listed
    fingerprints.append(f'{line}\t{listed[1]}\t{label}')
    if kind == 'ed25519':
        (fake / 'hostkey.pub').write_text(public + '\n')
(out / 'fingerprints.txt').write_text('\n'.join(fingerprints) + '\n')

kit = 'ShepherdKit/Sources/ShepherdKit'
sources = [f'{kit}/Resources.swift', f'{kit}/Agents/AgentKind.swift', f'{kit}/HerdrKit/HerdrClient.swift',
           f'{kit}/HerdrKit/Transport/HerdrTransport.swift', f'{kit}/HerdrKit/Transport/LocalHerdrTransport.swift',
           f'{kit}/HerdrKit/Transport/ConnectionFailureDescription.swift', f'{kit}/HerdrKit/Terminal/LocalCommand.swift',
           f'{kit}/HerdrKit/Terminal/HerdrExecutable.swift', f'{kit}/HerdrKit/Terminal/ShellQuoting.swift',
           f'{kit}/Machines/MachineMonitor.swift', f'{kit}/HerdrKit/Live/HerdrRefreshSchedule.swift',
           'Shepherd/Hosts/Views/LauncherMachineStep.swift']
sources += [str(x.relative_to(ROOT)) for x in sorted((ROOT / kit / 'HerdrKit/Models').glob('*.swift'))]
sources += [str(x.relative_to(ROOT)) for x in sorted((ROOT / kit / 'HerdrKit/HerdrMachineSetup').glob('*.swift'))]
# The launcher's targets, from the file they are in with SwiftUI and AppKit
# views, as Tests/Terminal/run-usability-tests.py takes them.
launcher = (ROOT / 'Shepherd/Hosts/Views/NewTabLauncher.swift').read_text()
start = launcher.index('struct LaunchTarget:')
end = launcher.index('/// How the launcher is asked to come up.', start)
(out / 'LaunchTargets.swift').write_text('import Foundation\n' + launcher[start:end])
tests = ['Tests/HerdrMachineSetup/HerdrMachineSetupTests.swift']
swiftc = ['xcrun', 'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor', '-parse-as-library',
          '-target', platform.machine() + '-apple-macos26.6.2']
stage('build', 300, swiftc + sources + [str(out / 'LaunchTargets.swift')] + tests + ['-o', str(out / 'herdr-machine-setup-tests')])
result = stage('tests', 600, [str(out / 'herdr-machine-setup-tests'), str(fake), str(out / 'fingerprints.txt')],
               {'PATH': f'{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin', 'SHEPHERD_FAKE_DIR': str(fake)})
print(result.strip().splitlines()[-1])

# This Mac only (SHPHRD-110): the rule, the launcher's row and the menus' item.
local_only = [f'{kit}/Machines/Machine.swift', 'Shepherd/Hosts/Views/LocalOnlyAddition.swift']
local_tests = ['Tests/HerdrMachineSetup/LocalOnlyAdditionTests.swift']
stage('local-only-build', 300, swiftc + sources + local_only + [str(out / 'LaunchTargets.swift')] + local_tests
      + ['-o', str(out / 'local-only-tests')])
local_result = stage('local-only-tests', 60, [str(out / 'local-only-tests')])
print(local_result.strip().splitlines()[-1])

# Where it is taken: the File menu, the host group header's menu, the
# launcher, the panel; Reconnect… and Remove… as they were.
read = lambda n: (ROOT / n).read_text()
content, app, board = read('Shepherd/ContentView.swift'), read('Shepherd/Shepherd.swift'), read('Shepherd/Hosts/Views/AgentBoardView.swift')
assert 'AddHerdrMachineMenuItem(unavailableReason: herdrMachineCommand?.addUnavailableReason,\n' \
       '                                    isEnabled: herdrMachineCommand?.canAdd == true) {\n' \
       '                herdrMachineCommand?.add()' in app, 'the File menu\'s item'
assert 'let localOnly = LocalOnlyAddition.herdrMachine.unavailableReason(on: machine)' in content
assert 'canAdd: isFree && monitor.canManageHerdrMachines && localOnly == nil,\n            addUnavailableReason: localOnly,' in content
assert 'canRemove: isFree && monitor.canManageHerdrMachines && !previewCoversTerminal(on: machine),' in content, 'Remove… as it was'
assert 'AddHerdrMachineOffer(on: machine, herdrBlocker: monitor(for: machine).herdrMachineManagementBlocker)' in content, 'the launcher\'s row'
assert 'addHerdrMachine: addHerdrMachineOffer(on: machine),' in content
show = content[content.index('    private func showHerdrMachineSetup('):content.index('        launcherStart = nil\n        isShowingPaneSwitcher = false')]
assert 'mode != .add || LocalOnlyAddition.herdrMachine.unavailableReason(on: machine) == nil,' in show, 'the panel opens to add on This Mac only'
change = content[content.index('        .onChange(of: machine?.connectionIdentity) {'):content.index('        .onChange(of: stalePreview(on: machine))')]
assert 'herdrMachineSetup?.close()' in change, 'a panel open as the window goes to another machine closes'
assert 'AddHerdrMachineMenuItem(unavailableReason: LocalOnlyAddition.herdrMachine.unavailableReason(on: machine),\n' \
       '                                            isEnabled: monitor.canManageHerdrMachines) { onHerdrMachineSetup(.add) }' in board, 'the host group header\'s item'
assert board.count('.disabled(!monitor.canManageHerdrMachines)') == 2 and 'Button("Reconnect…") { onHerdrMachineSetup(.reconnect(group.machine)) }' in board, \
    'Reconnect… and Remove… as they were'
swift = {str(x.relative_to(ROOT)): x.read_text() for x in (ROOT / 'Shepherd').rglob('*.swift')}
assert not [n for n, s in swift.items() if 'Button("Add herdr Machine…")' in s], 'every menu goes through AddHerdrMachineMenuItem'
assert sorted(n for n, s in swift.items() if 'LocalOnlyAddition.' in s) == ['Shepherd/ContentView.swift', 'Shepherd/Hosts/Views/AgentBoardView.swift',
                                                                          'Shepherd/Hosts/Views/LocalOnlyAddition.swift', 'Shepherd/Hosts/Views/MachinesSettingsView.swift']
assert not [x for x in (ROOT / 'ShepherdMobile').rglob('*.swift') if 'LocalOnlyAddition' in x.read_text() or 'Connect to This Mac' in x.read_text()], \
    'the iOS app left as it is'
strings = json.loads(read('Shepherd/Localizable.xcstrings'))['strings']
for key in ['Connect to This Mac to add a herdr machine.', 'Connect to This Mac to add a device.', 'Connect to This Mac to change this setting.']:
    assert all(strings[key]['localizations'][l]['stringUnit']['state'] == 'translated' for l in ['ko', 'ja']), key
stages.append('local-only-static-checks')

hashed = sources + tests + local_only + local_tests + ['Shepherd/Hosts/Views/NewTabLauncher.swift', 'Tests/HerdrMachineSetup/fake-ssh',
                                                       'Tests/HerdrMachineSetup/fake-herdr', 'Tests/HerdrMachineSetup/run-tests.py',
                                                       'Shepherd/ContentView.swift', 'Shepherd/Shepherd.swift', 'Shepherd/Hosts/Views/AgentBoardView.swift']
(out / 'source-hashes.json').write_text(json.dumps({n: hashlib.sha256((ROOT / n).read_bytes()).hexdigest() for n in sorted(hashed)}, indent=2))
(out / 'validation.json').write_text(json.dumps({'passed': True, 'stages': stages, 'summary': result.strip().splitlines()[-1],
                                                 'localOnlySummary': local_result.strip().splitlines()[-1], 'windowsShown': False,
                                                 'networkAccess': False, 'realSSH': False, 'realHerdrState': False,
                                                 'userSSHFilesRead': False, 'app': False}, indent=2))
print('passed:', ', '.join(stages))
