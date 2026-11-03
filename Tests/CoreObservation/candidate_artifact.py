"""Separate opt-in passive-observer candidate, never an official artifact.
A local receipt checks consistency, NOT authenticity of a third-party binary.
"""
from pathlib import Path
import hashlib
import json
import subprocess

HERE = Path(__file__).resolve().parent
RECIPE = HERE / 'backport/recipe.json'
BASE = HERE.parent / 'CoreProtocol/backport/recipe.json'
CHECKS = {'formatter-format', 'formatter-tests', 'build', 'core-library-tests', 'vt-library-tests', 'notices'}


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        while block := f.read(1 << 20): h.update(block)
    return h.hexdigest()


def require(ok, message):
    if not ok: raise ValueError(message)


def recipes():
    r, base = json.loads(RECIPE.read_text()), json.loads(BASE.read_text())
    require(digest(BASE) == r['baseRecipeSHA256'], 'base recipe changed')
    require(digest(BASE.parent / base['patchFile']) == base['patchSHA256'], 'OSC8 patch changed')
    require(digest(HERE / 'backport/core-observer.patch') == r['corePatchSHA256'], 'observer patch changed')
    require(digest(HERE / 'backport/ghostty-14725.patch') == r['ghostty14725SHA256'], 'background patch changed')
    return r, base


def verify_sources(workspace):
    r, _ = recipes(); core = workspace / 'core'; ghostty = core / 'vendor/ghostty'
    env = {'PATH':'/usr/bin:/bin', 'HOME':str(workspace/'home'), 'GIT_CONFIG_NOSYSTEM':'1', 'GIT_CONFIG_GLOBAL':'/dev/null'}
    def git(path, *args):
        return subprocess.check_output(['/usr/bin/git','-C',str(path),*args],env=env,text=True).strip()
    require(git(core,'rev-parse','HEAD') == r['coreCommit'], 'wrong core base')
    require(git(ghostty,'rev-parse','HEAD') == r['ghosttyCommit'], 'wrong Ghostty base')
    changed = set(git(core,'diff','HEAD','--name-only').splitlines()) | set(git(core,'ls-files','--others','--exclude-standard').splitlines())
    require(changed == set(r['coreFiles']) | {'vendor/ghostty'}, 'unexpected source/configuration changes')
    require(git(ghostty,'diff','HEAD','--name-only') == 'src/terminal/formatter.zig', 'unexpected Ghostty edits')
    require(not git(ghostty,'ls-files','--others','--exclude-standard'), 'untracked Ghostty files')
    for name, expected in r['coreFiles'].items():
        require(digest(core/name) == expected, 'candidate source differs: '+name)
    require(digest(core/'Cargo.lock') == r['cargoLockSHA256'], 'lockfile changed')
    require(digest(ghostty/'src/terminal/formatter.zig') == r['formatterSHA256'], 'formatter changed')
    return r


def select(receipt_path):
    path = Path(receipt_path).resolve()
    r, base = recipes(); value = json.loads(path.read_text())
    require(value.get('schema') == 1 and value.get('variant') == r['variant'] and value.get('officialRelease') is False, 'unsupported candidate')
    require(value.get('recipeSHA256') == digest(RECIPE), 'recipe changed')
    require(value.get('builderSHA256') == digest(HERE/'backport/build-candidate.py'), 'builder changed')
    require(value.get('validatorSHA256') == digest(Path(__file__).resolve()), 'validator changed')
    require(set(value.get('checks', {})) == CHECKS, 'incomplete candidate checks')
    for name, check in value['checks'].items():
        require(check.get('passed') is True and digest(path.parent/(name+'.log')) == check.get('logSHA256'), 'failed/missing/changed build check')
        if name in {'formatter-tests','core-library-tests','vt-library-tests'}:
            require(type(check.get('testCount')) is int and check['testCount'] > 0, 'zero tests')
    toolchain = value.get('toolchain', {})
    require(toolchain.get('rustc','').startswith('rustc 1.95.0 '), 'wrong Rust toolchain')
    require(toolchain.get('zig') == base['zigVersion'] and toolchain.get('zigSHA256') == base['zigBinarySHA256'], 'wrong Zig toolchain')
    require(value.get('binary') == 'herdr-core', 'invalid binary name')
    binary = path.parent/'herdr-core'
    require(not binary.is_symlink() and binary.is_file() and 0 < binary.stat().st_size <= 128 << 20, 'invalid candidate file')
    require(digest(binary) == value.get('binarySHA256'), 'candidate binary changed')
    return binary, value
