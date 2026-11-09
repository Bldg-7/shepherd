#!/usr/bin/env python3
import copy,subprocess,unittest,xml.etree.ElementTree as ET
from unittest.mock import patch
import product_build_policy as p
from hc_release_bundle import check_no_legacy_backend_symbols,BundlePolicyFailure
class ProductBuildPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.baseline=p.project_objects()
    def setUp(self):self.objects=copy.deepcopy(self.baseline)
    def rejected(self):
        with self.assertRaises(p.ProductBuildPolicyFailure):p.check_product_project(self.objects)
    def test_actual_product_and_fixture_partition(self):
        self.assertTrue(p.check_product_project()['normalDebugReleaseSeparated'])
        self.assertTrue(p.check_sdk_boundary()['sdkLegacySourceBoundaryDeclared'])
    def test_normal_product_cannot_link_fixture_sdk(self):
        self.objects[p.MAIN]['packageProductDependencies'].append('E1F100000000000000000009');self.rejected()
    def test_normal_product_cannot_depend_on_helper(self):
        self.objects['edge']={'target':p.FORWARDER};self.objects[p.MAIN]['dependencies'].append('edge');self.rejected()
    def test_normal_debug_cannot_reintroduce_cef(self):
        self.objects['000000000000000111000000']['buildSettings']['HEADER_SEARCH_PATHS']='Vendor/CEF/out';self.rejected()
    def test_normal_debug_cannot_enable_fixture_code(self):
        self.objects['000000000000000111000000']['buildSettings']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG SHEPHERD_LEGACY_FIXTURES';self.rejected()
    def test_each_product_variant_rejects_legacy_source(self):
        for identifier in ['000000000000000111000000','000000000000000112000000','5A11000000000000000000B9','5A11000000000000000000B10']:
            with self.subTest(configuration=identifier):
                self.objects=copy.deepcopy(self.baseline)
                self.objects[identifier]['buildSettings']['EXCLUDED_SOURCE_FILE_NAMES']=[];self.rejected()
    def test_normal_copy_phase_rejected(self):
        self.objects[p.MAIN]['buildPhases'].append('A9E100000000000000000002');self.rejected()
    def test_normal_deferred_resource_reference_rejected(self):
        self.objects['000000000000000140000000']['files'].append('A63E1D0D20AA408AA2C0C024');self.rejected()
    def test_normal_framework_reference_rejected(self):
        self.objects['000000000000000130000000']['files'].append('C0CB00000000000000000030');self.rejected()
    def test_fixture_cannot_be_installable(self):
        self.objects['E1F100000000000000000007']['buildSettings']['SKIP_INSTALL']='NO';self.rejected()
    def test_fixture_cannot_share_application_identity(self):
        self.objects['E1F100000000000000000007']['buildSettings']['PRODUCT_BUNDLE_IDENTIFIER']='com.bldg-7.shepherd';self.rejected()
    def test_normal_scheme_cannot_select_fixture(self):
        scheme=ET.parse(p.ROOT/'shepherd.xcodeproj/xcshareddata/xcschemes/Shepherd.xcscheme')
        scheme.find('.//BuildActionEntry/BuildableReference').set('BlueprintIdentifier',p.FIXTURE)
        with self.assertRaises(p.ProductBuildPolicyFailure):p.check_product_project(self.objects,scheme)
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
