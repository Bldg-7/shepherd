#!/usr/bin/env python3
import copy,subprocess,unittest,xml.etree.ElementTree as ET
from unittest.mock import patch
import product_build_policy as p
from hc_release_bundle import check_no_legacy_backend_symbols,BundlePolicyFailure
DEBUG='000000000000000111000000'
FRAMEWORKS='000000000000000130000000'
RESOURCES='000000000000000140000000'
class ProductBuildPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.baseline=p.project_objects()
    def setUp(self):self.objects=copy.deepcopy(self.baseline)
    def rejected(self,**kwargs):
        with self.assertRaises(p.ProductBuildPolicyFailure):p.check_product_project(self.objects,**kwargs)
    def test_actual_product_project_and_sdk(self):
        self.assertTrue(p.check_product_project()['noRetiredInputs'])
        self.assertTrue(p.check_sdk_boundary()['noLegacyFixtureSDK'])
    def test_retired_package_products_rejected(self):
        for target in [p.MAIN,p.MOBILE]:
            for product in sorted(p.RETIRED_PRODUCTS):
                with self.subTest(target=target,product=product):
                    self.objects=copy.deepcopy(self.baseline)
                    self.objects['retired-product']={'isa':'XCSwiftPackageProductDependency','productName':product}
                    self.objects[target]['packageProductDependencies'].append('retired-product');self.rejected()
    def test_extra_target_rejected(self):
        for name in ['Shepherd Legacy Fixtures','hrdrhrdrhrdr-agent-proxy']:
            with self.subTest(name=name):
                self.objects=copy.deepcopy(self.baseline)
                self.objects['extra-target']={'isa':'PBXNativeTarget','name':name,'buildPhases':[],'dependencies':[]};self.rejected()
    def test_target_dependency_rejected(self):
        self.objects['edge']={'isa':'PBXTargetDependency','target':'A9E100000000000000000060'}
        self.objects[p.MAIN]['dependencies']=['edge'];self.rejected()
    def test_fixture_scheme_rejected(self):
        self.rejected(scheme_names={'Shepherd.xcscheme','Shepherd Mobile.xcscheme','Shepherd Legacy Fixtures.xcscheme'})
    def test_cef_or_fixture_settings_rejected(self):
        for name,value in [('HEADER_SEARCH_PATHS','Vendor/CEF/out'),('OTHER_LDFLAGS','-lcef_dll_wrapper'),
                           ('SWIFT_ACTIVE_COMPILATION_CONDITIONS','DEBUG SHEPHERD_LEGACY_FIXTURES'),
                           ('PRODUCT_BUNDLE_IDENTIFIER','com.bldg-7.shepherd.legacy-fixtures')]:
            with self.subTest(setting=name):
                self.objects=copy.deepcopy(self.baseline)
                self.objects[DEBUG]['buildSettings'][name]=value;self.rejected()
    def test_copy_phase_rejected(self):
        self.objects['copy-phase']={'isa':'PBXCopyFilesBuildPhase','files':[]}
        self.objects[p.MAIN]['buildPhases'].append('copy-phase');self.rejected()
    def test_retired_resource_rejected(self):
        for name in sorted(p.RETIRED_PAYLOADS):
            with self.subTest(payload=name):
                self.objects=copy.deepcopy(self.baseline)
                self.objects['payload-ref']={'isa':'PBXFileReference','path':'Shepherd/'+name}
                self.objects['payload-build']={'isa':'PBXBuildFile','fileRef':'payload-ref'}
                self.objects[RESOURCES]['files'].append('payload-build');self.rejected()
    def test_retired_framework_rejected(self):
        self.objects['retired-product']={'isa':'XCSwiftPackageProductDependency','productName':'NIOSSL'}
        self.objects['framework-build']={'isa':'PBXBuildFile','productRef':'retired-product'}
        self.objects[FRAMEWORKS]['files'].append('framework-build');self.rejected()
    def test_normal_scheme_cannot_select_another_target(self):
        scheme=ET.parse(p.SCHEMES/'Shepherd.xcscheme')
        scheme.find('.//BuildActionEntry/BuildableReference').set('BlueprintIdentifier',p.MOBILE)
        self.rejected(scheme=scheme)
    def test_sdk_fixture_target_rejected(self):
        text=(p.ROOT/'ShepherdKit/Package.swift').read_text()
        for planted in ['.target(name: "ShepherdLegacyFixtures")','.define("SHEPHERD_LEGACY_FIXTURE_MODULE")']:
            with self.subTest(planted=planted),patch.object(p.Path,'read_text',return_value=text+planted):
                with self.assertRaises(p.ProductBuildPolicyFailure):p.check_sdk_boundary()
    def test_legacy_symbol_and_inspector_failures_rejected(self):
        for word in ['ShepherdKit.HerdrClient.init','ShepherdLegacyFixtures.TerminalSession.write','hrdrhrdrhrdr.AgentRuntime.run','hrdrhrdrhrdr.MachineMonitor.connect']:
            with self.subTest(symbol=word),patch('hc_release_bundle.subprocess.run',side_effect=[subprocess.CompletedProcess([],0,'_symbol',''),subprocess.CompletedProcess([],0,word,'')]):
                with self.assertRaises(BundlePolicyFailure):check_no_legacy_backend_symbols('fixture')
        for first,second in [(1,0),(0,1)]:
            with self.subTest(inspector=(first,second)),patch('hc_release_bundle.subprocess.run',side_effect=[subprocess.CompletedProcess([],first,'',''),subprocess.CompletedProcess([],second,'','')]):
                with self.assertRaises(BundlePolicyFailure):check_no_legacy_backend_symbols('fixture')
    def test_hc_and_shared_models_are_not_legacy_executables(self):
        with patch('hc_release_bundle.subprocess.run',side_effect=[subprocess.CompletedProcess([],0,'_symbol',''),subprocess.CompletedProcess([],0,'ShepherdKit.HcTerminalSession.write\nShepherdKit.AgentSummary.init\nShepherdKit.ConversationClient.load','')]):
            check_no_legacy_backend_symbols('fixture')
if __name__=='__main__':unittest.main()
