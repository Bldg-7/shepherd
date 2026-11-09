"""Fail-closed normal-product / explicitly nonshipping fixture build boundary."""
from pathlib import Path
import json,re,subprocess,xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[2]
MAIN='000000000000000100000000'
FIXTURE='E1F100000000000000000001'
FORWARDER='A9E100000000000000000060'
MOBILE='5A11000000000000000000B0'
class ProductBuildPolicyFailure(RuntimeError):pass

def project_objects():
    r=subprocess.run(['/usr/bin/plutil','-convert','json','-o','-',str(ROOT/'shepherd.xcodeproj/project.pbxproj')],capture_output=True,text=True,check=False,timeout=30)
    if r.returncode:raise ProductBuildPolicyFailure('cannot inspect product project')
    return json.loads(r.stdout)['objects']

def check_product_project(objects=None,scheme=None):
    objects=project_objects() if objects is None else objects
    scheme=ET.parse(ROOT/'shepherd.xcodeproj/xcshareddata/xcschemes/Shepherd.xcscheme') if scheme is None else scheme
    inventory=json.loads((ROOT/'Tests/HcBackend/legacy-fixture-sources.json').read_text())
    def require(test,message):
        if not test:raise ProductBuildPolicyFailure(message)
    def configs(target):
        return [objects[i]['buildSettings'] for i in objects[objects[target]['buildConfigurationList']]['buildConfigurations']]
    def products(target):return {objects[i]['productName'] for i in objects[target].get('packageProductDependencies',[])}
    for target,platform in [(MAIN,'macOS'),(MOBILE,'iOS')]:
        require('ShepherdLegacyFixtures' not in products(target),'normal product depends on fixture SDK')
        for edge in objects[target].get('dependencies',[]):
            require(objects[edge].get('target') not in {FIXTURE,FORWARDER},'normal product depends on fixture native target')
        for setting in configs(target):
            excluded=setting.get('EXCLUDED_SOURCE_FILE_NAMES',[])
            if isinstance(excluded,str):excluded=excluded.split()
            require({Path(p).name for p in inventory[platform]}<=set(excluded),'normal product admits a historical UI/launcher source')
            for name,value in setting.items():
                if name=='EXCLUDED_SOURCE_FILE_NAMES':continue
                text=(name+' '+str(value)).casefold()
                require(not any(word in text for word in ('shepherd_legacy_fixtures','vendor/cef','chromium','libcef')),'normal product has fixture/CEF compiler input')
    retired={'NIOSSL','X509','NIOHTTP1','NIOWebSocket','ShepherdLegacyFixtures'}
    require(not products(MAIN)&retired,'normal app links deferred browser/fixture product')
    for phase in objects[MAIN]['buildPhases']:
        data=objects[phase]
        require(data['isa']!='PBXCopyFilesBuildPhase','normal app retains deferred Copy Files phase')
        for entry in data.get('files',[]):
            build=objects[entry]
            require(objects.get(build.get('productRef'),{}).get('productName') not in retired,'normal Frameworks phase links deferred product')
            ref=objects.get(build.get('fileRef'),{})
            require(Path(ref.get('path','')).name not in {'AgentRuntime','ChromiumCredits.html','hrdrhrdrhrdr-agent-proxy'},'normal resource phase embeds deferred payload')
    # Resource build-file entries may be retained for the fixture target, but
    # normal resources must no longer reference those entries at all.
    for config in configs(FIXTURE):
        require(config.get('SKIP_INSTALL')=='YES','fixture app is installable')
        require(config.get('PRODUCT_BUNDLE_IDENTIFIER')=='com.bldg-7.shepherd.legacy-fixtures','fixture app shares product bundle identity')
        require(config.get('PRODUCT_MODULE_NAME')!='ShepherdLegacyFixtures','fixture application collides with SDK module')
        require('SHEPHERD_LEGACY_FIXTURES' in str(config.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS')),'fixture target lacks explicit compilation boundary')
    require('ShepherdLegacyFixtures' in products(FIXTURE),'fixture app lost its explicit historical SDK')
    entries=scheme.findall('.//BuildActionEntry/BuildableReference')
    require(bool(entries) and all(e.get('BlueprintIdentifier')==MAIN for e in entries),'ordinary scheme selects a fixture target')
    fixture_scheme=ET.parse(ROOT/'shepherd.xcodeproj/xcshareddata/xcschemes/Shepherd Legacy Fixtures.xcscheme')
    for entry in fixture_scheme.findall('.//BuildActionEntry'):
        require(entry.get('buildForArchiving')=='NO' and entry.get('buildForProfiling')=='NO','fixture scheme can archive/profile')
    return {'normalDebugReleaseSeparated':True,'fixtureExplicitAndNonshipping':True}

def check_sdk_boundary():
    text=(ROOT/'ShepherdKit/Package.swift').read_text()
    roots=json.loads((ROOT/'Tests/HcBackend/legacy-fixture-sources.json').read_text())['SDK']
    match=re.search(r'let legacyFixtureSources = \[(.*?)\]',text,re.S)
    if not match or re.findall(r'"([^"]+)"',match.group(1))!=roots:
        raise ProductBuildPolicyFailure('SDK fixture source inventory differs')
    if 'exclude: legacyFixtureSources' not in text or 'sources: legacyFixtureSources' not in text or '.define("SHEPHERD_LEGACY_FIXTURE_MODULE")' not in text:
        raise ProductBuildPolicyFailure('SDK fixture source boundary is missing')
    return {'sdkLegacySourceBoundaryDeclared':True}
