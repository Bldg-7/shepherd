#!/usr/bin/env python3
"""Negative acceptance tests for the named bounded stage launcher."""
import json
import pathlib
import subprocess
import sys

launcher = pathlib.Path(__file__).with_name('run-stage.py').resolve()
out = pathlib.Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)


def stage(name, script, expected, failure_record=False):
    log = out / (name + '.log')
    command = [sys.executable, str(launcher), '--timeout', '6', '--natural-exit-grace', '0.3', '--log', str(log)]
    if failure_record:
        command += ['--failure-cleanup-record', str(out / (name + '.failure.json'))]
    result = subprocess.run(command + ['--', sys.executable, '-c', script], stdout=subprocess.DEVNULL, timeout=12)
    record = json.loads(log.with_suffix('.stage.json').read_text())
    assert result.returncode == expected and record['exitCode'] == expected, name
    assert record['cleanupVerified'] and not record['survivorsAtCleanup'], name
    return record


healthy = stage('healthy', 'pass', 0)
assert healthy['naturalExitConfirmed'] and healthy['signalsSent'] == [] and healthy['preCleanupSurvivors'] == []
print('PASS: healthy normal exit requires no cleanup signals')

# Give the ownership watcher time to record a descendant in its own session.
leak = "import subprocess,threading; subprocess.Popen(['/bin/sleep','60'],start_new_session=True); threading.Event().wait(0.6)"
survivor = stage('healthy-survivor', leak, 1)
assert survivor['processExitCode'] == 0 and survivor['preCleanupSurvivors'] and survivor['signalsSent']
assert not survivor['naturalExitConfirmed']
print('PASS: exit-zero command with a surviving helper fails even after successful forced cleanup')

failure = stage('nonzero-survivor', leak + ';raise SystemExit(7)', 7)
assert failure['signalsSent'] and not failure['naturalExitConfirmed']
print('PASS: failure cleanup never turns a nonzero stage into success')

marker = out / 'controller-loss.failure.json'
script = f"import subprocess,threading,json; p=subprocess.Popen(['/bin/sleep','60'],start_new_session=True); threading.Event().wait(0.6); p.kill(); p.wait(); open({str(marker)!r},'w').write(json.dumps({{'kind':'controller-loss','appPID':p.pid,'code':None,'signal':'SIGKILL'}}))"
expected = stage('controller-loss', script, 0, True)
assert expected['expectedFailureCleanupVerified'] and not expected['naturalExitConfirmed']
assert expected['testFailureOutcome']['signal'] == 'SIGKILL'
print('PASS: verified controller-loss force stop is an explicit failure-path outcome, not healthy exit')

invalid = stage('missing-failure-proof', leak, 1, True)
assert not invalid['expectedFailureCleanupVerified'] and not invalid['naturalExitConfirmed']
print('PASS: failure-path flag alone cannot allow an unproved forced-cleanup pass')
