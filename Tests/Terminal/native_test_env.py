"""Fresh private test environment and a matching Xcode SDK/SwiftUI plugin pair."""
from pathlib import Path
import subprocess

def settings(out):
    developer = Path('/Applications/Xcode.app/Contents/Developer')
    env = {'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(out/'home'),
           'CFFIXED_USER_HOME':str(out/'home'),'TMPDIR':str(out/'tmp'),
           'CLANG_MODULE_CACHE_PATH':str(out/'cache'),'DEVELOPER_DIR':str(developer),
           'LANG':'en_US.UTF-8'}
    sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
    usr = developer/'Platforms/MacOSX.platform/Developer/usr'
    plugins = str(usr/'lib/swift/host/plugins')+'#'+str(usr/'bin/swift-plugin-server')
    return env, ['-sdk',sdk,'-external-plugin-path',plugins]
