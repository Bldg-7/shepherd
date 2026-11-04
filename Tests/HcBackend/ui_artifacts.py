"""Delete only retired, unregistered copies made by the owned hc UI runner."""
from pathlib import Path
import json, os, shutil, stat

def remove_staged_bundles(root, registration, *, retirement_verified):
    root = Path(root)
    if not retirement_verified:
        raise RuntimeError('owned app/helper/core retirement is unconfirmed')
    if root.is_symlink() or root.resolve().parent != Path('/private/tmp') or not root.name.startswith('hc-screen-app.'):
        raise RuntimeError('not an owned hc UI scratch root')
    if root.stat().st_uid != os.getuid():
        raise RuntimeError('scratch root owner differs')
    expected = [root/'OwnedShepherd.app', root/'OwnedUILauncher.app']
    record = json.loads((root/'fixture-bundle.json').read_text())
    if record.get('bundle') != str(expected[0]) or record.get('helper') != str(expected[1]):
        raise RuntimeError('staging manifest does not identify these exact copies')
    if len(registration) != 2 or {r.get('bundle') for r in registration} != {str(p) for p in expected} or any(r.get('exitCode') != 0 for r in registration):
        raise RuntimeError('owned LaunchServices registrations were not removed')
    # Validate both before deleting either. rmtree does not follow bundle symlinks.
    for path in expected:
        s = path.lstat()
        if not stat.S_ISDIR(s.st_mode) or s.st_uid != os.getuid():
            raise RuntimeError('staged bundle is not an owned directory')
    for path in expected:
        shutil.rmtree(path)
    return [str(p) for p in expected]
