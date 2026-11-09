#!/usr/bin/env python3
"""Inspect both Xcode Debug's launcher and its actual debug image; no launch.
Release auditing stays strict and never accepts this as a signed export gate.
"""
from pathlib import Path
import argparse,json,plistlib,subprocess
from hc_release_bundle import check_hc_payload,check_no_cef_symbols,check_no_legacy_backend_symbols,BundlePolicyFailure

def inspect_debug_product(app):
    app=Path(app);result=check_hc_payload(app)
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    if info.get('CFBundleExecutable')!='hrdrhrdrhrdr':raise BundlePolicyFailure('unexpected Debug executable')
    binary=app/'Contents/MacOS/hrdrhrdrhrdr';image=binary.with_name(binary.name+'.debug.dylib')
    def run(args):
        r=subprocess.run(args,capture_output=True,text=True,check=False,timeout=30)
        if r.returncode:raise BundlePolicyFailure('Debug image inspection failed')
        return r.stdout
    arches=set(run(['/usr/bin/lipo','-archs',str(binary)]).split())
    if not arches:raise BundlePolicyFailure('missing Debug architecture')
    main_load=run(['/usr/bin/otool','-L',str(binary)])
    if not image.is_file() or image.is_symlink() or '@rpath/hrdrhrdrhrdr.debug.dylib' not in main_load:
        raise BundlePolicyFailure('expected exact Xcode Debug launcher/image pair')
    if set(run(['/usr/bin/lipo','-archs',str(image)]).split())!=arches:
        raise BundlePolicyFailure('Debug launcher/image architecture mismatch')
    for path in [binary,image]:
        check_no_cef_symbols(path);check_no_legacy_backend_symbols(path)
        for arch in arches:
            load=run(['/usr/bin/otool','-arch',arch,'-L',str(path)])
            if 'Chromium Embedded Framework' in load or '3rdr Helper' in load:
                raise BundlePolicyFailure('Debug image loads excluded browser runtime')
            if path==image and '@rpath/Sparkle.framework/' not in load:
                raise BundlePolicyFailure('Debug implementation image lost updater dependency')
    return {**result,'passed':True,'actualDebugImageInspected':str(image),'architectures':sorted(arches),
            'legacyExecutableSDKSymbols':False,'cefImplementationSymbols':False,'releaseExportQualified':False}
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--app',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    try:r=inspect_debug_product(a.app)
    except (OSError,BundlePolicyFailure) as error:p.exit(1,'error: '+str(error)+'\n')
    a.output.write_text(json.dumps(r,indent=2));print(json.dumps(r,indent=2))
