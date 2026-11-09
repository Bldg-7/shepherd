#!/usr/bin/env python3
"""Offline hc packaging guards; synthetic layout is not binary/release qualification."""
from pathlib import Path
import importlib.util, os, subprocess, tempfile, unittest
from unittest.mock import patch
from hc_release_bundle import check_hc_payload, inspect_binary, check_no_cef_symbols, BundlePolicyFailure
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
               'Contents/Resources/hidden/AGENTRUNTIME/file',
               'Contents/Resources/ChromiumCredits.html']
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
    def test_cef_symbol_and_inspector_failures_rejected(self):
        for symbol in ['_cef_initialize','__ZN22CefScopedLibraryLoader4LoadEv','_CEF_something']:
            with self.subTest(symbol=symbol), patch('hc_release_bundle.subprocess.run',
                    return_value=subprocess.CompletedProcess([],0,symbol+'\n','')):
                with self.assertRaisesRegex(BundlePolicyFailure,'CEF implementation/wrapper'):
                    check_no_cef_symbols(self.root/'fixture')
        with patch('hc_release_bundle.subprocess.run',return_value=subprocess.CompletedProcess([],1,'','invalid')):
            with self.assertRaisesRegex(BundlePolicyFailure,'cannot inspect'):
                check_no_cef_symbols(self.root/'fixture')
    def test_source_profile_and_reviewed_pins(self):
        inv=notices.check_source()
        for name in ['swiftterm','swift-argument-parser','swift-certificates']:
            self.assertNotIn(name,notices.REMOTE_REVISIONS)
        with patch.dict(notices.REMOTE_REVISIONS,{'swift-certificates':'f4cd9e78a1ec209b27e426a5f5c693675f95e75a'}):
            with self.assertRaisesRegex(notices.NoticeFailure,'Package.resolved drift'):
                notices.check_dependency_graph(inv)
    def test_archive_gate_has_no_named_empty_success_path(self):
        inv=notices.load_inventory()
        for roots in [[self.root],[self.root,self.root/'fake.xcarchive']]:
            with self.assertRaises(notices.NoticeFailure):
                notices.check_products(inv,self.app,roots)
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
        self.assertNotIn('run: scripts/cef.sh',workflow)
        self.assertNotIn('CEF_BUILD_ROOT=',script)
        self.assertNotIn('SHEPHERD_CEF_ROOT=',script)
        self.assertIn('Tests/Terminal/SwiftTermWrap/verify-vendor.py',workflow)
        for required in ['codesign --verify --deep --strict', 'notarize "$WORK/notarize.zip"',
                         'spctl --assess --type execute', 'notary_ready', 'Push the exact reviewed source commit']:
            self.assertIn(required,script)

if __name__=='__main__': unittest.main()
