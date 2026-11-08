#!/usr/bin/env python3
"""Strict hc Release payload policy. Reads only the supplied bundle; never launches it."""
from pathlib import Path
import argparse, json, os, plistlib, subprocess

class BundlePolicyFailure(RuntimeError):
    pass

def forbidden_name(name):
    name = name.casefold()
    return (name in {'agentruntime', 'node_modules', 'chromium embedded framework.framework',
                     'hrdrhrdrhrdr-agent-proxy'} or name.startswith('3rdr helper') or
            (name.startswith('com.bldg-7.shepherd.agent-proxy') and name.endswith('.plist')))

def check_hc_payload(app):
    app = Path(app).absolute()
    if app.is_symlink() or not app.is_dir() or app.suffix != '.app':
        raise BundlePolicyFailure('expected an existing .app bundle')
    forbidden = []
    # Inspect this artifact only. Do not follow framework links outside it or
    # scan any user HOME/service/archives. Dangling forbidden links also fail.
    for directory, dirs, files in os.walk(app, followlinks=False):
        for name in dirs + files:
            item = Path(directory)/name
            if item.is_symlink():
                target = Path(os.path.normpath(os.path.join(directory, os.readlink(item))))
                if not target.is_relative_to(app):
                    raise BundlePolicyFailure('bundle link escapes artifact: ' + str(item.relative_to(app)))
            if forbidden_name(name):
                forbidden.append(str(item.relative_to(app)))
    if forbidden:
        raise BundlePolicyFailure('excluded integration payload present: ' + ', '.join(sorted(forbidden)))
    return {'excludedPayloadsAbsent':True,'inspectedBundle':str(app),
            'browserFrameworkOrHelpers':False,'agentRuntime':False,'captureExecutableOrLaunchAgent':False}

def inspect_binary(app):
    app=Path(app)
    try:
        info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    except (OSError,plistlib.InvalidFileException) as error:
        raise BundlePolicyFailure('invalid app Info.plist') from error
    if info.get('CFBundleExecutable') != 'hrdrhrdrhrdr' or info.get('CFBundlePackageType') != 'APPL':
        raise BundlePolicyFailure('unexpected product executable/type')
    binary=app/'Contents/MacOS/hrdrhrdrhrdr'
    if not binary.is_file() or not binary.stat().st_size:
        raise BundlePolicyFailure('missing main executable')
    arch=subprocess.run(['/usr/bin/lipo','-archs',str(binary)],capture_output=True,text=True,check=False)
    load=subprocess.run(['/usr/bin/otool','-L',str(binary)],capture_output=True,text=True,check=False)
    if arch.returncode or not arch.stdout.split() or load.returncode:
        raise BundlePolicyFailure('main executable is not valid Mach-O')
    if 'Chromium Embedded Framework' in load.stdout or '3rdr Helper' in load.stdout:
        raise BundlePolicyFailure('excluded browser runtime still required by a load command')
    if '@rpath/Sparkle.framework/' not in load.stdout:
        raise BundlePolicyFailure('expected updater dependency is missing')
    return {'architectures':arch.stdout.split(),'version':info.get('CFBundleShortVersionString'),
            'browserLoadCommand':False,'signingQualified':False,'notarizationQualified':False}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    try:
        result={**check_hc_payload(args.app),**inspect_binary(args.app),'passed':True,
                'legacyCodeDependenciesRetired':False,'installedAppOrServiceChanged':False}
    except (BundlePolicyFailure,OSError) as error:
        parser.exit(1,'error: '+str(error)+'\n')
    if args.output: args.output.write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2))

if __name__=='__main__': main()
