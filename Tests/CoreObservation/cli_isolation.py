"""Private CLI qualification boundary. No caller environment/credentials inherited.
Only executable/package code and public OS runtime files are readable; only the
owned scratch directory and terminal devices are writable. All networking and
Mach service lookup (including keychain/pasteboard brokers) are denied.
"""
from pathlib import Path
import hashlib
import json
import os
import subprocess


def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        while b:=f.read(1<<20):h.update(b)
    return h.hexdigest()


def package_roots(entry):
    entry=Path(entry).resolve()
    root=entry
    while not (root/'package.json').is_file():
        if root==root.parent:raise ValueError('package root unavailable')
        root=root.parent
    modules=next(p for p in root.parents if p.name=='node_modules')
    pending=[root]; seen=set()
    while pending:
        p=pending.pop().resolve()
        if p in seen:continue
        if not p.is_relative_to(modules):raise ValueError('package link leaves code installation')
        seen.add(p)
        info=json.loads((p/'package.json').read_text())
        for name in set(info.get('dependencies',{}))|set(info.get('optionalDependencies',{})):
            for base in [p,*p.parents]:
                if not base.is_relative_to(modules.parent):break
                candidate=base/'node_modules'/name
                if (candidate/'package.json').is_file():
                    pending.append(candidate);break
        if len(seen)>1024:raise ValueError('dependency graph limit')
    return sorted(seen)


def environment(home, node):
    home=Path(home).resolve()
    for name in ['tmp','config','state','cache','pi-agent','sessions','codex','claude']:
        (home/name).mkdir(mode=0o700,parents=True,exist_ok=True)
    return {'PATH':str(Path(node).parent)+':/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(home),
        'CFFIXED_USER_HOME':str(home),'TMPDIR':str(home/'tmp'),'XDG_CONFIG_HOME':str(home/'config'),
        'XDG_STATE_HOME':str(home/'state'),'XDG_CACHE_HOME':str(home/'cache'),
        'CODEX_HOME':str(home/'codex'),'CLAUDE_CONFIG_DIR':str(home/'claude'),
        'PI_CODING_AGENT_DIR':str(home/'pi-agent'),'PI_CODING_AGENT_SESSION_DIR':str(home/'sessions'),
        'PI_OFFLINE':'1','PI_SKIP_VERSION_CHECK':'1','PI_TELEMETRY':'0','PI_IMAGE_PROTOCOL':'none',
        'DISABLE_AUTOUPDATER':'1','DISABLE_TELEMETRY':'1','DISABLE_ERROR_REPORTING':'1',
        'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC':'1','CLAUDE_CODE_TMPDIR':str(home/'tmp'),'DO_NOT_TRACK':'1',
        'TERM':'xterm-256color','LANG':'en_US.UTF-8'}


def profile(root, executables, packages, tty_path=None, core_runtime=False, core_home=None, missing_config_roots=()):
    root=Path(root).resolve()
    # Actual resolved files, not user-home symlinks; code directories are public
    # installed packages, not .pi/agent, .claude, .codex or bridge resources.
    public=['/System/Library','/usr/lib','/usr/share','/bin','/sbin','/usr/bin','/usr/sbin',
            '/Library/Apple/System/Library','/private/etc/ssl','/dev/fd']
    literals=['/dev/null','/dev/urandom','/dev/random','/dev/tty','/private/etc/localtime',
              '/private/etc/resolv.conf','/private/etc/hosts','/etc']
    read_roots=[root,*map(Path,public),*map(Path,packages)]
    files=[*map(Path,literals),*map(Path,executables)]
    if tty_path:files.append(Path(tty_path))
    parents=set()
    for p in [*read_roots,*files]:parents.update(p.parents)
    path=lambda kind,p:'('+kind+' '+json.dumps(str(p))+')'
    text='(version 1)\n(allow default)\n(deny mach-lookup)\n'
    if core_runtime:
        if core_home is None or not Path(core_home).resolve().is_relative_to(root):raise ValueError('private core home required')
        text+='(deny network* (require-not '+path('subpath',Path(core_home).resolve())+'))\n'
        text+='(deny process-info* (require-not (target same-sandbox)))\n(allow process-info-listpids)\n'
        text+='(deny signal (require-not (target same-sandbox)))\n'
    else:
        text+='(deny network*)\n'
        text+='(deny process-info*)\n(allow process-info* (target self))\n(deny signal)\n(allow signal (target self))\n'
    # Public OS/VM queries are needed by the allocator. Process argument and
    # environment sysctls are not; deny that family rather than all sysctls.
    text+='(deny sysctl-read (sysctl-name-regex #"^kern\\\\.proc"))\n'
    # An unconditional deny(file-read*) wins over allow(file-read*) on macOS.
    # Deny the complement instead. Literal ancestors permit traversal/directory
    # metadata, not reading arbitrary child files in a personal home.
    readable=' '.join(path('subpath',p) for p in read_roots)+' '+' '.join(path('literal',p) for p in [*files,*sorted(parents)])
    writable=path('subpath',root)+' (literal "/dev/null") (literal "/dev/tty") (subpath "/dev/fd")'+(' '+path('literal',tty_path) if tty_path else '')
    if core_runtime:
        # hc allocates the PTYs after the one inherited sandbox is installed.
        # No global keyboard/window input is used by the fixture; this device
        # allowance is not a claim of isolation from all same-user tty devices.
        devices=' (literal "/dev/ptmx") (regex #"^/dev/ttys[0-9A-Za-z]+$")'
        readable+=devices;writable+=devices
    # Let absent system-policy lookups return ENOENT, but never read a real
    # policy file or silently replace it. Existing regular files stay denied.
    for config_root in missing_config_roots:
        # Missing paths can reach the sandbox before symlink normalization.
        for variant in sorted({Path(config_root).absolute(),Path(config_root).resolve()}):
            readable+=' (require-all '+path('subpath',variant)+' (require-not (vnode-type REGULAR-FILE)))'
    text+='(deny file-read* (require-not (require-any '+readable+')))\n'
    text+='(deny file-write* (require-not (require-any '+writable+')))\n'
    text+='(deny file-read* (subpath "/Library/Keychains") (subpath "/System/Library/Keychains"))\n'
    # No external credential/helper executables. Node's own process and the
    # pinned CLIs can execute; version/help/TUI tests cannot invoke security/op.
    text+='(deny process-exec)\n(allow process-exec '+' '.join(path('literal',p) for p in executables)+')\n'
    return text


PI_FLAGS=['--offline','--no-extensions','--no-mcp','--no-skills','--no-prompt-templates','--no-themes','--no-context-files','--no-approve','--no-tools']
