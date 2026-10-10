"""Owned-test-only observational instrumentation; never reports or reads transcripts."""
import json, os, pathlib, re, sys, time, fcntl, hashlib, difflib, shlex


def record(category, **fields):
    try:
        target = pathlib.Path(__file__).with_name('hook-diagnostics.json')
        with target.open('a+', encoding='utf-8') as handle:
            os.chmod(target, 0o600)
            fcntl.flock(handle, fcntl.LOCK_EX)
            handle.seek(0)
            try: rows = json.load(handle)
            except Exception: rows = []
            rows.append(dict(at=time.time(), category=category, **fields))
            handle.seek(0); handle.truncate(); json.dump(rows[-128:], handle)
    except Exception:
        pass


def invocation(file, action):
    try:
        value = json.loads(pathlib.Path(file).read_text())
        if not isinstance(value, dict): value = {}
    except Exception: value = {}
    sid = value.get('session_id'); event = value.get('hook_event_name'); transcript = value.get('transcript_path')
    canonical = os.path.realpath(transcript) if isinstance(transcript, str) and transcript.strip() else None
    home = str(pathlib.Path(__file__).parent.parent)
    location = canonical if canonical and canonical.startswith(home + '/.codex/sessions/') else None
    guard = 'shell-pass'
    if action != 'session': guard = 'action'
    elif os.environ.get('HERDR_ENV') != '1': guard = 'herdr-env'
    elif not os.environ.get('HERDR_SOCKET_PATH'): guard = 'socket-context'
    elif not os.environ.get('HERDR_PANE_ID'): guard = 'pane-context'
    record('invocation', guard=guard, event=event if event in ['SessionStart', None] else 'other',
           sessionID=sid if isinstance(sid, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,256}', sid) else None,
           types={k:type(value.get(k)).__name__ for k in ['session_id','hook_event_name','source','transcript_path']},
           source=value.get('source') if value.get('source') in ['startup','resume','clear','compact'] else 'other-or-absent',
           transcriptPresent='transcript_path' in value, transcriptCanonicalLocation=location,
           transcriptUnderOwnedSessions=bool(location),
           contextPresent={k:bool(os.environ.get(k)) for k in ['HERDR_ENV','HERDR_SOCKET_PATH','HERDR_PANE_ID']},
           threadPresent=bool(os.environ.get('CODEX_THREAD_ID')),
           threadEqualsInput=os.environ.get('CODEX_THREAD_ID') == sid if os.environ.get('CODEX_THREAD_ID') else None)


def response(data):
    try:
        value = json.loads(data)
        record('report-response', responseType=type(value).__name__, success=isinstance(value, dict) and 'result' in value and not value.get('error'),
               errorType=type(value.get('error')).__name__ if isinstance(value, dict) and 'error' in value else 'absent',
               resultType=type(value.get('result')).__name__ if isinstance(value, dict) and 'result' in value else 'absent')
    except Exception: record('report-response', responseType='unparsed')


def install(hook, evidence):
    hook = pathlib.Path(hook); evidence = pathlib.Path(evidence)
    original = hook.read_text(); module = str(pathlib.Path(__file__).resolve())
    text = original
    def replace(old, new):
        nonlocal text
        if text.count(old) != 1: raise RuntimeError('unsupported built-in hook boundary')
        text = text.replace(old, new)
    replace('case "$action" in', 'if command -v python3 >/dev/null 2>&1; then\n  python3 ' + shlex.quote(module) + ' invocation "$hook_input_file" "$action" || true\nfi\n\ncase "$action" in')
    replace('source = "herdr:codex"', 'import importlib.util\n_spec = importlib.util.spec_from_file_location("owned_diagnostic", ' + repr(module) + ')\n_diag = importlib.util.module_from_spec(_spec)\n_spec.loader.exec_module(_diag)\n\nsource = "herdr:codex"')
    for condition, category in [('if not pane_id or not socket_path:', 'python-context'), ('if hook_event_name and hook_event_name != "SessionStart":', 'event'), ('if not isinstance(transcript_path, str) or not transcript_path.strip():', 'transcript'), ('if inherited_session_id and inherited_session_id != agent_session_id:', 'thread-mismatch')]:
        replace(condition + '\n    raise SystemExit(0)', condition + '\n    _diag.record("guard", guard=' + repr(category) + ')\n    raise SystemExit(0)')
    replace('else:\n    raise SystemExit(0)\n\ntry:', 'else:\n    _diag.record("guard", guard="session-id")\n    raise SystemExit(0)\n\n_diag.record("report-attempt")\ntry:')
    replace('        client.recv(4096)\n    except Exception:\n        pass', '        _diag.response(client.recv(4096))\n    except Exception as error:\n        _diag.record("receive-error", errorType=type(error).__name__)\n        pass')
    replace('except Exception:\n    pass\nPY', 'except Exception as error:\n    _diag.record("socket-error", errorType=type(error).__name__)\n    pass\nPY')
    hook.write_text(text)
    (evidence/'codex-hook-original.sh').write_text(original)
    (evidence/'codex-hook-instrumented.sh').write_text(text)
    (evidence/'codex-hook-observational.patch').write_text(''.join(difflib.unified_diff(original.splitlines(True), text.splitlines(True))))
    (evidence/'codex-hook-hashes.json').write_text(json.dumps({'original':hashlib.sha256(original.encode()).hexdigest(), 'instrumented':hashlib.sha256(text.encode()).hexdigest(), 'mode':oct(hook.stat().st_mode & 0o777)}))
    for name in ['codex-hook-original.sh','codex-hook-instrumented.sh','codex-hook-observational.patch','codex-hook-hashes.json']: os.chmod(evidence/name,0o600)


if __name__ == '__main__':
    if sys.argv[1] == 'install': install(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == 'invocation': invocation(sys.argv[2], sys.argv[3])
