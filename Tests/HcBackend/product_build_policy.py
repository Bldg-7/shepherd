"""Fail-closed product build boundary: the macOS and iOS apps carry no
retired browser, capture-service or legacy-fixture inputs, and the removed
fixture app/scheme/SDK do not come back."""
from pathlib import Path
import json,re,subprocess,xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[2]
MAIN='000000000000000100000000'
MOBILE='5A11000000000000000000B0'
SCHEMES=ROOT/'shepherd.xcodeproj/xcshareddata/xcschemes'
# Package products the apps no longer link: the deferred browser's TLS/HTTP
# stack and the historical fixture SDK.
RETIRED_PRODUCTS={'NIOSSL','X509','NIOHTTP1','NIOWebSocket','ShepherdLegacyFixtures'}
# Words that only the CEF browser or the fixture partition put in settings.
RETIRED_SETTING_WORDS=('shepherd_legacy_fixture','legacy-fixtures','vendor/cef','chromium','libcef','cef_dll')
# Bundle payloads of the retired browser, Node agent runtime and capture service.
RETIRED_PAYLOADS={'AgentRuntime','ChromiumCredits.html','hrdrhrdrhrdr-agent-proxy'}
class ProductBuildPolicyFailure(RuntimeError):pass

def project_objects():
    r=subprocess.run(['/usr/bin/plutil','-convert','json','-o','-',str(ROOT/'shepherd.xcodeproj/project.pbxproj')],capture_output=True,text=True,check=False,timeout=30)
    if r.returncode:raise ProductBuildPolicyFailure('cannot inspect product project')
    return json.loads(r.stdout)['objects']

def check_product_project(objects=None,scheme=None,scheme_names=None):
    objects=project_objects() if objects is None else objects
    scheme=ET.parse(SCHEMES/'Shepherd.xcscheme') if scheme is None else scheme
    scheme_names={p.name for p in SCHEMES.glob('*.xcscheme')} if scheme_names is None else scheme_names
    def require(test,message):
        if not test:raise ProductBuildPolicyFailure(message)
    def configs(target):
        return [objects[i]['buildSettings'] for i in objects[objects[target]['buildConfigurationList']]['buildConfigurations']]
    def products(target):return {objects[i]['productName'] for i in objects[target].get('packageProductDependencies',[])}
    targets={k:v for k,v in objects.items() if v.get('isa') in ('PBXNativeTarget','PBXAggregateTarget','PBXLegacyTarget')}
    require(set(targets)=={MAIN,MOBILE},'project has a target other than the macOS and iOS apps: '+', '.join(sorted(v.get('name','?') for v in targets.values())))
    require(not scheme_names-{'Shepherd.xcscheme','Shepherd Mobile.xcscheme'},'project has a scheme other than the two apps\'')
    for target in (MAIN,MOBILE):
        require(not products(target)&RETIRED_PRODUCTS,'product links a retired browser/fixture package product')
        require(not objects[target].get('dependencies'),'product depends on another native target')
        for setting in configs(target):
            for name,value in setting.items():
                text=(name+' '+str(value)).casefold()
                require(not any(word in text for word in RETIRED_SETTING_WORDS),'product has fixture/CEF compiler input: '+name)
    for phase in objects[MAIN]['buildPhases']:
        data=objects[phase]
        require(data['isa']!='PBXCopyFilesBuildPhase','macOS app retains a Copy Files phase')
        for entry in data.get('files',[]):
            build=objects[entry]
            require(objects.get(build.get('productRef'),{}).get('productName') not in RETIRED_PRODUCTS,'Frameworks phase links a retired product')
            ref=objects.get(build.get('fileRef'),{})
            require(Path(ref.get('path','')).name not in RETIRED_PAYLOADS,'resource phase embeds a retired payload')
    entries=scheme.findall('.//BuildActionEntry/BuildableReference')
    require(bool(entries) and all(e.get('BlueprintIdentifier')==MAIN for e in entries),'ordinary scheme selects another target')
    return {'onlyProductTargets':True,'noFixtureSchemeOrTarget':True,'noRetiredInputs':True}

def check_sdk_boundary():
    text=(ROOT/'ShepherdKit/Package.swift').read_text()
    if re.search(r'ShepherdLegacyFixture|SHEPHERD_LEGACY_FIXTURE|legacyFixtureSources',text):
        raise ProductBuildPolicyFailure('ShepherdKit declares a legacy fixture target or source set')
    return {'noLegacyFixtureSDK':True}
