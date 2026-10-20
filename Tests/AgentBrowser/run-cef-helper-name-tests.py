#!/usr/bin/env python3
"""The CEF helper apps' name: the same in every place it is spelled, and in a built app.

CEF starts its sub-processes from the path BrowserEngine.mm gives it
(browser_subprocess_path) and finds the other four helpers next to that one, in
the app's Frameworks folder, by adding " (Alerts)", " (GPU)", " (Plugin)" and
" (Renderer)" to its name. A name changed in only some of the places still
builds, and the whole app goes down the first time the browser starts (0.5.0).

Without --app this reads the sources: scripts/cef.sh (the name and the
suffixes), CEFHelper/Info.plist.in, scripts/sign-cef.py, the Xcode project's
file references and Embed Browser Engine phase, and BrowserEngine.mm. With
--app <path to the .app> it also checks a built app: exactly those five helpers
in Contents/Frameworks, each one's executable and Info.plist, the path the app's
own code hands CEF, and each helper's signature. Nothing is started, signed or
written; scripts/release-macos.sh runs it on the exported app.

Usage: Tests/AgentBrowser/run-cef-helper-name-tests.py [--app <path>]
"""
import argparse
import ast
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# The helpers CEF looks for on macOS, by the suffix on the first one's name.
SUFFIXES = ['', ' (Alerts)', ' (GPU)', ' (Plugin)', ' (Renderer)']
# The helpers' earlier name, which nothing should spell any more.
OLD_NAME = 'Shepherd Helper'

checks = 0
failures = []


def check(ok, message):
    global checks
    checks += 1
    if not ok:
        failures.append(message)
        print('FAIL', message)


def read(relative):
    return (ROOT / relative).read_text()


def sources():
    """The helpers' names as scripts/cef.sh builds them, after checking that
    every other place spells them the same way. Returns (name, ids)."""
    cef = read('scripts/cef.sh')
    names = re.findall(r'^HELPER_NAME="([^"]+)"$', cef, re.M)
    check(len(names) == 1, 'scripts/cef.sh sets HELPER_NAME once')
    name = names[0] if names else ''
    block = re.search(r'^HELPERS=\(\n(.*?)^\)$', cef, re.M | re.S)
    check(block is not None, 'scripts/cef.sh lists the helpers in HELPERS')
    entries = re.findall(r'^\s*"([^"]*)"$', block.group(1), re.M) if block else []
    suffixes = [entry.split(':')[0] for entry in entries]
    check(suffixes == SUFFIXES, f'scripts/cef.sh builds the five helpers CEF looks for: {suffixes}')
    ids = {name + entry.split(':')[0]: 'com.bldg-7.shepherd.helper' + entry.split(':')[1] for entry in entries}
    helpers = [name + suffix for suffix in SUFFIXES]

    plist = plistlib.loads((ROOT / 'CEFHelper/Info.plist.in').read_bytes())
    check(all(plist.get(key) == '@NAME@' for key in ['CFBundleExecutable', 'CFBundleName', 'CFBundleDisplayName']),
          'CEFHelper/Info.plist.in takes the executable, bundle and display name from scripts/cef.sh')
    check(plist.get('CFBundleIdentifier') == 'com.bldg-7.shepherd.helper@ID_SUFFIX@',
          'CEFHelper/Info.plist.in keeps the bundle IDs com.bldg-7.shepherd.helper*')

    sign = read('scripts/sign-cef.py')
    lists = re.findall(r'^for name in (\[[^\]\n]*\]):', sign, re.M)
    check(len(lists) == 1 and ast.literal_eval(lists[0]) == helpers,
          f'scripts/sign-cef.py signs the same five helpers: {lists}')

    project = read('shepherd.xcodeproj/project.pbxproj')
    references = dict((path[:-len('.app')], ref) for ref, path in re.findall(
        r'^\t\t(\w{24}) /\* [^*]+ \*/ = \{isa = PBXFileReference; lastKnownFileType = wrapper\.application; '
        r'path = "([^"]+\.app)"; sourceTree = "<group>"; \};$', project, re.M))
    check(sorted(references) == sorted(helpers), f'the Xcode project refers to the same five helpers: {sorted(references)}')
    group = re.search(r'/\* Browser Engine \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \((.*?)\);\n'
                      r'\t\t\tname = "Browser Engine";\n\t\t\tpath = Vendor/CEF/out;', project, re.S)
    check(group is not None and all(ref in group.group(1) for ref in references.values()),
          'the helpers are in the Browser Engine group, which is Vendor/CEF/out')
    embedded = dict(re.findall(r'^\t\t(\w{24}) /\* [^*]+ in Embed Browser Engine \*/ = \{isa = PBXBuildFile; '
                               r'fileRef = (\w{24}) /\* [^*]+ \*/; platformFilters = \(macos, \); '
                               r'settings = \{ATTRIBUTES = \(CodeSignOnCopy, \); \}; \};$', project, re.M))
    phase = re.search(r'^\t\t(\w{24}) /\* Embed Browser Engine \*/ = \{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n'
                      r'\t\t\tdstPath = "";\n\t\t\tdstSubfolder = Frameworks;\n\t\t\tfiles = \((.*?)\);', project, re.M | re.S)
    check(phase is not None, 'the Xcode project has the Embed Browser Engine phase, into Frameworks')
    for helper, ref in references.items():
        copies = [build for build, file in embedded.items() if file == ref]
        check(len(copies) == 1 and phase is not None and copies[0] in phase.group(2),
              f'Embed Browser Engine copies {helper}.app into Frameworks, signing it on copy')
    target = re.search(r'/\* Shepherd \*/ = \{\n\t\t\tisa = PBXNativeTarget;.*?buildPhases = \((.*?)\);', project, re.S)
    check(phase is not None and target is not None and phase.group(1) in target.group(1),
          'the app target runs Embed Browser Engine')

    engine = read('Shepherd/Browser/Engine/BrowserEngine.mm')
    paths = re.findall(r'@"([^"]*)\.app/Contents/MacOS/([^"]*)"', engine)
    check(paths == [(name, name)], f'BrowserEngine.mm hands CEF {name}.app/Contents/MacOS/{name}: {paths}')
    check('CefString(&settings.browser_subprocess_path) = helper.UTF8String;' in engine,
          'BrowserEngine.mm sets browser_subprocess_path to that path')

    for relative in ['scripts/cef.sh', 'scripts/sign-cef.py', 'scripts/release-macos.sh', 'shepherd.xcodeproj/project.pbxproj',
                     'Shepherd/Browser/Engine/BrowserEngine.mm', 'CEFHelper/main.cc', 'CEFHelper/Info.plist.in']:
        check(OLD_NAME not in read(relative), f'{relative} no longer says {OLD_NAME}')
    return name, ids


def subprocess_paths(binary):
    """Every C string in `binary` of the form '<... Helper...>.app/Contents/MacOS/<...>'."""
    data = binary.read_bytes()
    found = set()
    for match in re.finditer(rb'\.app/Contents/MacOS/', data):
        start = data.rfind(b'\0', 0, match.start()) + 1
        end = data.find(b'\0', match.end())
        text = data[start:end if end >= 0 else len(data)]
        if b'Helper' in text and len(text) < 512:
            found.add(text.decode('utf-8', 'replace'))
    return found


def app(path, name, ids):
    contents = path / 'Contents'
    frameworks = contents / 'Frameworks'
    check(frameworks.is_dir(), f'{frameworks} exists')
    if not frameworks.is_dir():
        return
    helpers = [name + suffix for suffix in SUFFIXES]
    bundles = sorted(entry.name for entry in frameworks.iterdir() if entry.name.endswith('.app'))
    check(bundles == sorted(helper + '.app' for helper in helpers),
          f'Contents/Frameworks holds exactly the five helpers, and no older ones: {bundles}')
    for helper in helpers:
        bundle = frameworks / (helper + '.app')
        executable = bundle / 'Contents' / 'MacOS' / helper
        check(executable.is_file() and not executable.is_symlink() and os.access(executable, os.X_OK),
              f'{helper}.app/Contents/MacOS/{helper} is an executable file')
        try:
            info = plistlib.loads((bundle / 'Contents' / 'Info.plist').read_bytes())
        except (OSError, plistlib.InvalidFileException):
            info = {}
        check(info.get('CFBundleExecutable') == helper and info.get('CFBundleName') == helper,
              f'{helper}.app names itself {helper} (CFBundleExecutable {info.get("CFBundleExecutable")!r}, CFBundleName {info.get("CFBundleName")!r})')
        check(info.get('CFBundleIdentifier') == ids.get(helper),
              f'{helper}.app has the bundle ID {ids.get(helper)}: {info.get("CFBundleIdentifier")!r}')
        verify = subprocess.run(['codesign', '--verify', '--strict', str(bundle)], capture_output=True, text=True, timeout=60)
        check(verify.returncode == 0, f'codesign --verify --strict {helper}.app: {verify.stderr.strip()}')

    # The path is compiled into the app's own code: its executable, or in a
    # Debug build the debug dylib beside it that holds the code.
    main = plistlib.loads((contents / 'Info.plist').read_bytes()).get('CFBundleExecutable', '')
    binaries = [contents / 'MacOS' / main, contents / 'MacOS' / (main + '.debug.dylib')]
    found = set().union(*(subprocess_paths(binary) for binary in binaries if binary.is_file()))
    expected = f'{name}.app/Contents/MacOS/{name}'
    check(found == {expected}, f"the app's code hands CEF {expected}: {sorted(found)}")
    check((frameworks / expected).is_file(), f'Contents/Frameworks/{expected} is there for CEF to start')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--app', type=Path, help='a built .app to check as well')
    args = parser.parse_args()
    name, ids = sources()
    if args.app:
        app(args.app.resolve(), name, ids)
    if failures:
        print(f'FAILED {len(failures)} of {checks} CEF helper name checks')
        return 1
    print(f'PASS {checks} CEF helper name checks: {name}' + (f', in {args.app}' if args.app else ', sources only'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
