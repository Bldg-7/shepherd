#!/usr/bin/env python3
"""Offline hc packaging guards; synthetic layout is not binary/release qualification."""
from pathlib import Path
import importlib.util, json, os, tempfile, unittest
from hc_release_bundle import check_hc_payload, inspect_binary, BundlePolicyFailure
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('notice_gate',ROOT/'Tests/Notices/run-notices-tests.py')
notices=importlib.util.module_from_spec(spec); spec.loader.exec_module(notices)

class ReleaseBundlePolicyTests(unittest.TestCase):
    def setUp(self):
        parent=os.environ.get('HC_PACKAGING_TEST_ROOT')
        self.temp=tempfile.TemporaryDirectory(prefix='hc-release-layout.',dir=parent)
        self.root=Path(self.temp.name)
        self.app=self.root/'Fixture.app'; (self.app/'Contents/Resources').mkdir(parents=True)
    def tearDown(self): self.temp.cleanup()
    def plant(self,relative):
        path=self.app/relative; path.parent.mkdir(parents=True,exist_ok=True); path.write_text('fixture-only')
    def test_clean_layout_is_only_payload_qualification(self):
        self.assertTrue(check_hc_payload(self.app)['excludedPayloadsAbsent'])
        with self.assertRaises(BundlePolicyFailure): inspect_binary(self.app)
    def test_each_deferred_payload_rejected(self):
        paths=['Contents/Resources/AgentRuntime/runtime.mjs','Contents/Resources/Extra/node_modules/pkg/package.json',
               'Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/engine',
               'Contents/Frameworks/3rdr Helper.app/Contents/MacOS/helper',
               'Contents/Frameworks/3rdr Helper (GPU).app/Contents/MacOS/helper',
               'Contents/MacOS/hrdrhrdrhrdr-agent-proxy',
               'Contents/Library/LaunchAgents/com.bldg-7.shepherd.agent-proxy.plist',
               'Contents/Library/LaunchAgents/com.bldg-7.shepherd.agent-proxy.debug.plist',
               'Contents/Resources/hidden/AGENTRUNTIME/file']
        for index,relative in enumerate(paths):
            with self.subTest(path=relative):
                candidate=self.root/('case-'+str(index)+'.app'); candidate.mkdir()
                path=candidate/relative; path.parent.mkdir(parents=True); path.write_text('fixture-only')
                with self.assertRaises(BundlePolicyFailure): check_hc_payload(candidate)
    def test_forbidden_dangling_link_rejected(self):
        (self.app/'Contents/Resources/AgentRuntime').symlink_to('absent')
        with self.assertRaises(BundlePolicyFailure): check_hc_payload(self.app)
    def test_external_link_rejected_without_following_it(self):
        (self.app/'Contents/Resources/link').symlink_to(self.root/'outside')
        with self.assertRaises(BundlePolicyFailure): check_hc_payload(self.app)
    def test_internal_framework_link_allowed(self):
        framework=self.app/'Contents/Frameworks/Allowed.framework'
        (framework/'Versions/A').mkdir(parents=True)
        (framework/'Versions/Current').symlink_to('A',target_is_directory=True)
        self.assertTrue(check_hc_payload(self.app)['excludedPayloadsAbsent'])
    def test_hc_source_profile_and_reviewed_pin_delta(self):
        inv=notices.check_source(hc_product=True)
        with self.assertRaisesRegex(notices.NoticeFailure,'Package.resolved drift'):
            notices.check_dependency_graph(inv,hc_product=False)
        self.assertEqual(notices.HC_REMOVED_REMOTE_PINS,{'swiftterm','swift-argument-parser'})
    def test_archive_gate_has_no_named_empty_success_path(self):
        inv=notices.load_inventory()
        for roots in [[self.root],[self.root,self.root/'fake.xcarchive']]:
            with self.assertRaises(notices.NoticeFailure):
                notices.check_products(inv,self.app,roots,hc_product=True)
    def test_hc_profile_does_not_remove_signature_or_publish_gates(self):
        script=(ROOT/'scripts/release-macos.sh').read_text()
        self.assertIn('hc_release_bundle.py',script)
        self.assertIn('--profile hc --app "$APP" --products "$ARCHIVE" "$DERIVED"',script)
        self.assertNotIn('python3 "$ROOT/scripts/sign-cef.py"',script)
        self.assertNotIn('Prepare the locked browser runtime before archiving',script)
        self.assertIn('DERIVED="$WORK/DerivedData"',script)
        workflow=(ROOT/'.github/workflows/release-macos.yml').read_text()
        self.assertNotIn('npm ci --prefix Shepherd/Agents/AgentRuntime',workflow)
        self.assertNotIn('security/plugins.json',workflow)
        self.assertIn('Tests/Terminal/SwiftTermWrap/verify-vendor.py',workflow)
        for required in ['codesign --verify --deep --strict', 'notarize "$WORK/notarize.zip"',
                         'spctl --assess --type execute', 'notary_ready', 'Push the exact reviewed source commit']:
            self.assertIn(required,script)

if __name__=='__main__': unittest.main()
