#!/usr/bin/env python3
"""Bounded, owned-file-only preview checks; never uses user files/credentials."""
from pathlib import Path
import argparse,os,json,subprocess,sys,hashlib,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--swiftterm-products',type=Path);args=p.parse_args();out=args.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['home','tmp','cache','files']:(out/name).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
sources=['Shepherd/FilePreview/FilePreviewLink.swift','Shepherd/FilePreview/FilePreviewReader.swift','Shepherd/FilePreview/MarkdownPreview.swift','Shepherd/FilePreview/PreviewSyntaxHighlighter.swift','Shepherd/FilePreview/PreviewSyntaxRendering.swift','Shepherd/Hosts/Models/Machine.swift','Tests/FilePreview/FilePreviewTests.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources},indent=2))
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 v=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and v['naturalExitConfirmed'] and not v['signalsSent'] and v['cleanupVerified'],name
stage('preview-build',90,['xcrun','swiftc','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library',*sources,'-o',str(out/'preview-tests')])
stage('preview-tests',20,[str(out/'preview-tests'),str(out/'files')])
# Compile an explicit in-memory Citadel test module to enable the production
# SFTP routing branch. This module has no network or executeCommand API.
modules=out/'remote-modules';modules.mkdir(mode=0o700)
marker=out/'TestNIO.swift';marker.write_text('public enum OwnedNIOMarker {}\n')
helpers=out/'TestHelpers.swift';helpers.write_text('public final class NIOLockedValueBox<T>: @unchecked Sendable { public init(_ value: T) {} }\n')
for module,file in [('NIOCore',marker),('NIOConcurrencyHelpers',helpers),('Citadel',ROOT/'Tests/FilePreview/OwnedSFTPModule.swift')]:
 stage(module+'-owned-module',60,['xcrun','swiftc','-swift-version','6','-emit-library','-emit-module','-module-name',module,str(file),'-emit-module-path',str(modules/(module+'.swiftmodule')),'-o',str(modules/('lib'+module+'.dylib'))])
remote=['Shepherd/FilePreview/FilePreviewLink.swift','Shepherd/FilePreview/FilePreviewReader.swift','Shepherd/Hosts/Models/Machine.swift','Tests/FilePreview/RemoteReaderTests.swift']
stage('remote-reader-build',90,['xcrun','swiftc','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-I',str(modules),'-L',str(modules),'-lCitadel','-lNIOCore','-lNIOConcurrencyHelpers','-Xlinker','-rpath','-Xlinker',str(modules),*remote,'-o',str(out/'remote-reader-tests')])
stage('remote-reader-tests',20,[str(out/'remote-reader-tests')])
(out/'remote-source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in remote+['Tests/FilePreview/OwnedSFTPModule.swift']},indent=2))
model=['Shepherd/FilePreview/FilePreviewLink.swift','Shepherd/FilePreview/FilePreviewReader.swift','Shepherd/FilePreview/FilePreviewModel.swift','Shepherd/Hosts/Models/Machine.swift','Shepherd/Hosts/Models/MachineStore.swift','Shepherd/Hosts/Models/KeychainStore.swift','Tests/FilePreview/ModelTests.swift']
stage('preview-model-build',90,['xcrun','swiftc','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-I',str(modules),'-L',str(modules),'-lCitadel','-lNIOCore','-lNIOConcurrencyHelpers','-Xlinker','-rpath','-Xlinker',str(modules),*model,'-o',str(out/'preview-model-tests')])
stage('preview-model-tests',40,[str(out/'preview-model-tests'),str(out/'files')])
(out/'model-source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in model},indent=2))
if args.swiftterm_products:
 import shutil
 products=args.swiftterm_products.resolve()
 bundle=products/'SwiftTerm_SwiftTerm.bundle'
 if bundle.exists():shutil.copytree(bundle,out/bundle.name)
 native=['Shepherd/FilePreview/FilePreviewLink.swift','Shepherd/FilePreview/TerminalFileHit.swift','Shepherd/Terminal/TerminalFileGesture.swift','Shepherd/Terminal/TerminalHostView.swift','Tests/FilePreview/TerminalLinkTests.swift']
 stage('terminal-link-build',90,['xcrun','swiftc','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-I',str(products),*native,str(products/'SwiftTerm.o'),'-framework','AppKit','-framework','QuartzCore','-framework','CoreText','-o',str(out/'terminal-link-tests')])
 stage('terminal-link-tests',20,[str(out/'terminal-link-tests')])
 (out/'native-source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in native},indent=2))
(out/'validation.json').write_text(json.dumps({'passed':True,'userFilesRead':False,'realKeychainAccess':False,'networkAccess':False,'actualSwiftTerm':bool(args.swiftterm_products),'stages':11 if args.swiftterm_products else 9},indent=2))
