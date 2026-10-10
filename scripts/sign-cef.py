#!/usr/bin/env python3
"""Sign owned CEF build inputs inside-out before Xcode validates embedded apps.

An explicit existing Developer ID SHA-1 fingerprint is required. No key export,
Keychain changes, entitlement expansion or --deep signing is performed.
"""
from pathlib import Path
import argparse,os,re,subprocess

p=argparse.ArgumentParser();p.add_argument('--identity',required=True);a=p.parse_args()
assert re.fullmatch('[A-Fa-f0-9]{40}',a.identity),'Use an explicit certificate fingerprint'
root=Path(__file__).resolve().parent.parent
out=root/'Vendor/CEF/out';framework=out/'Chromium Embedded Framework.framework'
assert framework.is_dir(),'Prepare pinned CEF before signing'
identities=subprocess.check_output(['security','find-identity','-v','-p','codesigning'],text=True,timeout=15)
assert re.search(re.escape(a.identity)+r' "Developer ID Application: [^\n]+ \(SYZS4D43Z6\)"',identities,re.I),'Expected existing Developer ID team/identity not available'
def sign(path,entitlements=None):
 assert path.resolve().is_relative_to(out.resolve()),'Signing target escaped owned CEF output'
 command=['codesign','--force','--sign',a.identity,'--options','runtime','--timestamp']
 if entitlements:command+=['--entitlements',str(entitlements)]
 subprocess.run([*command,str(path)],check=True,timeout=120)
 os.utime(path,None)
for library in sorted((framework/'Versions/A/Libraries').glob('*.dylib')):sign(library)
sign(framework)
for name in ['Shepherd Helper','Shepherd Helper (Alerts)','Shepherd Helper (GPU)','Shepherd Helper (Plugin)','Shepherd Helper (Renderer)']:
 bundle=out/(name+'.app');assert bundle.is_dir(),name
 entitlement=root/'CEFHelper'/('Helper-Plugin.entitlements' if name.endswith('(Plugin)') else 'Helper.entitlements')
 sign(bundle,entitlement)
 subprocess.run(['codesign','--verify','--deep','--strict',str(bundle)],check=True,timeout=30)
subprocess.run(['codesign','--verify','--deep','--strict',str(framework)],check=True,timeout=30)
print('CEF inputs signed and verified with the explicit Developer ID; no application publication performed')
