#!/usr/bin/env python3
"""Bounded stages with natural-exit evidence and positively owned cleanup.

A successful healthy command must also leave no live descendants without any
runner signal. Cleanup after a failure never converts that failure into a pass.
The controller-loss test has a separately verified, app-scoped failure outcome.
No command argv (which may contain credentials) is persisted.
"""
import argparse
import datetime
import json
import os
import pathlib
import signal
import subprocess
import threading
import time


def processes():
    data = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,stat=,lstart=,command='],
                                   text=True, errors='replace', timeout=3)
    result = {}
    for row in data.splitlines():
        parts = row.split(None, 9)
        if len(parts) != 10 or parts[3].startswith('Z'):
            continue
        try:
            pid, parent, group = map(int, parts[:3])
        except ValueError:
            continue
        result[pid] = (parent, group, ' '.join(parts[4:9]), parts[9])
    return result


def matches(current, recorded):
    return current is not None and current[2:] == recorded[2:]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--timeout', type=float, required=True)
    parser.add_argument('--natural-exit-grace', type=float, default=5)
    parser.add_argument('--log', type=pathlib.Path, required=True)
    parser.add_argument('--cwd', type=pathlib.Path)
    parser.add_argument('--env', action='append', default=[])
    parser.add_argument('--failure-cleanup-record', type=pathlib.Path)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    args.log.parent.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
    for entry in args.env:
        key, value = entry.split('=', 1)
        environment[key] = value
    start = time.monotonic()
    record = {'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'deadlineSeconds': args.timeout, 'stage': args.log.stem, 'timedOut': False,
              'inspectionErrors': [], 'signalsSent': [], 'preCleanupSurvivors': [],
              'naturalExitConfirmed': False, 'expectedFailureCleanupVerified': False,
              'outcome': 'controller-loss' if args.failure_cleanup_record else 'healthy'}
    owned = {}
    wake = threading.Event()
    interrupted = []

    def snapshot():
        try:
            return processes()
        except (OSError, subprocess.SubprocessError) as error:
            if len(record['inspectionErrors']) < 4:
                record['inspectionErrors'].append(type(error).__name__)
            return {}

    def observe():
        current = snapshot()
        for pid, identity in current.items():
            if pid == child.pid or identity[1] == child.pid:
                owned.setdefault(pid, identity)
        for _ in range(8):
            for pid, identity in current.items():
                if identity[0] in owned and matches(current.get(identity[0]), owned[identity[0]]):
                    owned.setdefault(pid, identity)
        return {pid: identity for pid, identity in owned.items() if matches(current.get(pid), identity)}

    def interrupt(signum, frame):
        interrupted.append(signum)
        wake.set()

    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    print(f'{record["stage"]}: start, deadline={args.timeout}s', flush=True)
    with args.log.open('wb') as output:
        try:
            child = subprocess.Popen(command, cwd=args.cwd, env=environment, stdout=output,
                                     stderr=subprocess.STDOUT, start_new_session=True)
        except OSError as error:
            output.write(str(error).encode())
            record.update(exitCode=127, processExitCode=127, cleanupVerified=True,
                          survivorsAtCleanup=[], ownedProcesses=[],
                          elapsedSeconds=round(time.monotonic() - start, 3),
                          endedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
            args.log.with_suffix('.stage.json').write_text(json.dumps(record, indent=2))
            return 127
        record['pid'] = child.pid
        while True:
            observe()
            code = child.poll()
            if code is not None:
                break
            remaining = args.timeout - (time.monotonic() - start)
            if interrupted or remaining <= 0:
                record['timedOut'] = not interrupted
                code = 128 + interrupted[0] if interrupted else 124
                record['interruptedBy'] = interrupted
                for pid, identity in observe().items():
                    if '/Shepherd.app/Contents/MacOS/Shepherd' in identity[3]:
                        try:
                            subprocess.run(['/usr/bin/sample', str(pid), '1', '-file', str(args.log.with_suffix(f'.{pid}.sample.txt'))],
                                           stdout=output, stderr=output, timeout=5)
                        except (OSError, subprocess.TimeoutExpired):
                            pass
                break
            wake.wait(min(0.2, remaining))
        record['processExitCode'] = child.poll()

        # Give successful stages bounded time for natural helper termination.
        # The original stage deadline is never extended by this drain.
        if code == 0 and not interrupted:
            drain_deadline = min(start + args.timeout, time.monotonic() + args.natural_exit_grace)
            while observe() and not interrupted and time.monotonic() < drain_deadline:
                wake.wait(min(0.1, max(0, drain_deadline - time.monotonic())))
        live = observe()
        record['preCleanupSurvivors'] = sorted(live)
        allowed_failure = set()
        failure_valid = False
        if args.failure_cleanup_record:
            try:
                failure = json.loads(args.failure_cleanup_record.read_text())
                app_pid = failure['appPID']
                failure_valid = (failure['kind'] == 'controller-loss' and failure['code'] is None and
                                 failure['signal'] == 'SIGKILL' and app_pid in owned)
                if failure_valid:
                    allowed_failure.add(app_pid)
                    for _ in range(8):
                        allowed_failure.update(pid for pid, value in owned.items() if value[0] in allowed_failure)
                    record['testFailureOutcome'] = failure
            except (OSError, ValueError, KeyError, TypeError):
                pass
        unapproved_survivors = set(live) - allowed_failure
        if code == 0:
            if args.failure_cleanup_record:
                if not failure_valid or unapproved_survivors:
                    code = 1
            elif live:
                code = 1
        record['naturalExitConfirmed'] = (code == 0 and not args.failure_cleanup_record and
                                          not live and not record['inspectionErrors'] and not interrupted)

        # Failure cleanup remains bounded and signals only identity-matched
        # descendants. Every signal is recorded, including signals to groups.
        for sig in (signal.SIGTERM, signal.SIGKILL):
            current = observe()
            if child.poll() is None and child.pid not in current:
                try:
                    os.killpg(child.pid, sig)
                    record['signalsSent'].append({'group': child.pid, 'signal': sig.name,
                                                  'reason': 'live unreaped Popen session'})
                except ProcessLookupError:
                    pass
            for pid in current:
                if not matches(snapshot().get(pid), owned[pid]):
                    continue
                try:
                    os.kill(pid, sig)
                    record['signalsSent'].append({'pid': pid, 'signal': sig.name,
                                                  'expectedControllerFailure': pid in allowed_failure})
                except ProcessLookupError:
                    pass
            if sig == signal.SIGTERM and current:
                drain_deadline = time.monotonic() + 2
                while observe() and time.monotonic() < drain_deadline:
                    wake.wait(0.1)
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            code = 1 if code == 0 else code
        survivors = observe()
        record['survivorsAtCleanup'] = sorted(survivors)
        record['cleanupVerified'] = not record['inspectionErrors'] and not survivors
        unapproved_signals = any(not item.get('expectedControllerFailure', False) for item in record['signalsSent'])
        if code == 0 and args.failure_cleanup_record and unapproved_signals:
            code = 1
        record['expectedFailureCleanupVerified'] = (bool(args.failure_cleanup_record) and failure_valid and
                                                     not unapproved_survivors and not unapproved_signals and
                                                     record['cleanupVerified'] and code == 0)
        if code == 0 and (not record['cleanupVerified'] or interrupted):
            code = 1
        if code == 0 and not args.failure_cleanup_record and record['signalsSent']:
            code = 1
            record['naturalExitConfirmed'] = False
        record['ownedProcesses'] = [{'pid': pid, 'parent': value[0], 'group': value[1], 'started': value[2]}
                                    for pid, value in owned.items()]
        record['exitCode'] = code
        record['elapsedSeconds'] = round(time.monotonic() - start, 3)
        record['endedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    args.log.with_suffix('.stage.json').write_text(json.dumps(record, indent=2))
    print(f'{record["stage"]}: exit={code}, natural={record["naturalExitConfirmed"]}, signals={len(record["signalsSent"])}', flush=True)
    return code


if __name__ == '__main__':
    raise SystemExit(main())
