#!/usr/bin/env python3
"""Render the production pane-header components in owned iPhone/iPad simulators.
No existing simulator, app installation, SSH session or credential is used.
"""
from pathlib import Path
import argparse, hashlib, json, os, plistlib, signal, subprocess, sys, uuid
ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(); p.add_argument('--output', type=Path, required=True); p.add_argument('--runtime', default='com.apple.CoreSimulator.SimRuntime.iOS-27-0'); p.add_argument('--legacy-badge', action='store_true'); a = p.parse_args()
out = a.output.resolve(); out.mkdir(parents=True, mode=0o700, exist_ok=False)
app = out/'PaneHeaderLayoutHarness.app'; app.mkdir()
bundle = 'com.bldg7.shepherd.tests.header.'+uuid.uuid4().hex
sources = ['ShepherdMobile/PaneHeaderViews.swift', 'Tests/Mobile/PaneHeaderLayoutHarness.swift']
(out/'source-hashes.json').write_text(json.dumps({f:hashlib.sha256((ROOT/f).read_bytes()).hexdigest() for f in sources+['ShepherdMobile/BoardView.swift','ShepherdMobile/ConversationView.swift','ShepherdMobile/MachinesView.swift','ShepherdKit/Sources/ShepherdKit/Resources/Localizable.xcstrings','Tests/Mobile/run-pane-header-tests.py']},indent=2))
sdk = subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
compiled_sources=[str(ROOT/f) for f in sources]
if a.legacy_badge:
    text=(ROOT/sources[0]).read_text(); start=text.index('        ZStack {',text.index('struct PaneStatusBadge')); end=text.index('\n    }\n}',start)
    legacy='''        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)'''
    mutant=out/'LegacyPaneHeader.swift';mutant.write_text(text[:start]+legacy+text[end:]);compiled_sources[0]=str(mutant)
cmd = ['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-module-name','PaneHeaderLayoutHarness','-sdk',sdk,'-target','arm64-apple-ios26.0-simulator',*compiled_sources,'-framework','UIKit','-framework','SwiftUI','-o',str(app/'PaneHeaderLayoutHarness')]
result = subprocess.run(cmd,capture_output=True,text=True,timeout=120)
(out/'compile.log').write_text(result.stdout+result.stderr)
assert result.returncode == 0, 'compile failed; see compile.log'
info = {'CFBundleExecutable':'PaneHeaderLayoutHarness','CFBundleIdentifier':bundle,'CFBundleName':'Pane Header Layout Tests','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0','CFBundleVersion':'1','CFBundleSupportedPlatforms':['iPhoneSimulator'],'LSRequiresIPhoneOS':True,'MinimumOSVersion':'26.0','UIDeviceFamily':[1,2],'UILaunchScreen':{},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Layout','UISceneDelegateClassName':'PaneHeaderLayoutHarness.LayoutSceneDelegate'}]}}}
(app/'Info.plist').write_bytes(plistlib.dumps(info))
strings=json.loads((ROOT/'ShepherdKit/Sources/ShepherdKit/Resources/Localizable.xcstrings').read_text())['strings']
keys=['Idle','Working','Blocked','Done','Unknown']
labels={'en':keys,**{lang:[strings[k]['localizations'][lang]['stringUnit']['value'] for k in keys] for lang in ['ko','ja']}}
(app/'labels.json').write_text(json.dumps(labels,ensure_ascii=False))
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True,timeout=30)
created = []; results = []
def stop(signum, frame): raise KeyboardInterrupt()
signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
def sim(*args, timeout=120, check=True):
    return subprocess.run(['xcrun','simctl',*args],text=True,capture_output=True,timeout=timeout,check=check)
devices=[('iPhone','com.apple.CoreSimulator.SimDeviceType.iPhone-17'),('iPad','com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M3')]
if a.legacy_badge: devices=devices[:1]
try:
    for name, device_type in devices:
        udid = sim('create','Owned-PaneHeader-'+name+'-'+uuid.uuid4().hex[:8],device_type,a.runtime).stdout.strip()
        created.append(udid); (out/'owned-devices.json').write_text(json.dumps(created))
        try:
            sim('boot',udid)
            boot = sim('bootstatus',udid,'-b',timeout=240)
            (out/(name+'-boot.log')).write_text(boot.stdout+boot.stderr)
            sim('install',udid,str(app))
            launch = sim('launch','--console',udid,bundle,timeout=360,check=False)
            (out/(name+'-run.log')).write_text(launch.stdout+launch.stderr)
            container = Path(sim('get_app_container',udid,bundle,'data').stdout.strip())
            report = json.loads((container/'Documents/layout-results.json').read_text())
            (out/(name+'-results.json')).write_text(json.dumps(report,indent=2))
            results.append(report)
            print(name,len(report['cases']),'cases;',len(report['failures']),'failures',flush=True)
        finally:
            sim('terminate',udid,bundle,check=False)
            sim('shutdown',udid,check=False)
            sim('delete',udid)
            created.remove(udid); (out/'owned-devices.json').write_text(json.dumps(created))
finally:
    for udid in created[:]:
        sim('terminate',udid,bundle,check=False);sim('shutdown',udid,check=False);sim('delete',udid,check=False)
        created.remove(udid)
    (out/'owned-devices.json').write_text(json.dumps(created))
if a.legacy_badge:
    assert len(results)==1 and any('badge' in failure for failure in results[0]['failures']), 'legacy negative control did not detect the badge regression'
    (out/'verification.json').write_text(json.dumps({'expectedLegacyFailure':True,'ownedDevicesRemoved':True},indent=2))
    print('PASS negative control: original flexible badge fails the native layout checks')
    sys.exit(0)
assert len(results)==2 and all(r['passed'] for r in results), 'layout failure; see per-device results'
conversation=(ROOT/'ShepherdMobile/ConversationView.swift').read_text()
assert '.navigationTitle(destination.title)' in conversation and 'PaneStatusBadge(title: state.title,' in conversation
assert 'StateBadge(state: state, showsActivity: model.failure == nil)' in conversation
assert 'showsActivity: showsActivity && state == .working' in conversation
assert 'placement: .principal' not in conversation, 'native inline title keeps its compression and back-navigation behavior'
assert '[AgentState.idle, .working, .blocked, .done, .unknown].map(\\.title)' in conversation
badge=(ROOT/'ShepherdMobile/PaneHeaderViews.swift').read_text()
assert 'var showsActivity = false' in badge and '@Environment(\\.accessibilityReduceMotion)' in badge
assert 'if showsActivity {' in badge and 'ProgressView()' in badge and 'Image(systemName: "circle.fill")' in badge
assert '.accessibilityElement(children: .ignore)' in badge and '.accessibilityLabel(Text(title))' in badge
board=(ROOT/'ShepherdMobile/BoardView.swift').read_text()
assert 'PaneRow(pane: pane, showsWorkingActivity: showsWorkingActivity)' in board
assert 'showsActivity: showsWorkingActivity && pane.state == .working' in board
assert 'monitor.hasLoaded && monitor.loadError == nil' in board
assert 'group.hasLoaded && group.error == nil' in board
assert 'private struct CachedPaneRow' in board and 'PaneStatusBadge' not in board[board.index('private struct CachedPaneRow'):board.index('private struct PaneRow')]
machines=(ROOT/'ShepherdMobile/MachinesView.swift').read_text()
assert 'MobileToolbarIcon(title: "About"' in machines and 'MobileToolbarIcon(title: "Add Machine"' in machines
(out/'verification.json').write_text(json.dumps({'passed':True,'cases':sum(len(r['cases']) for r in results),'statesRendered':['idle','working','working-reduce-motion','blocked','done','unknown'],'ownedDevicesRemoved':True,'existingDevicesUntouched':True,'credentialsOrNetworkUsed':False,'nativeNavigationStack':True,'runtime':a.runtime},indent=2))
print('PASS mobile pane title/status/button layout on iPhone and iPad')
