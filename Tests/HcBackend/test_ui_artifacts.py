import json
from pathlib import Path
import tempfile
import unittest
from ui_artifacts import remove_staged_bundles

class Artifacts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='hc-screen-app.', dir='/private/tmp')
        self.root = Path(self.temp.name).resolve()
        self.app = self.root/'OwnedShepherd.app'; self.helper = self.root/'OwnedUILauncher.app'
        for p in [self.app,self.helper]:p.mkdir();(p/'dummy').write_text('owned test bundle')
        (self.root/'fixture-bundle.json').write_text(json.dumps({'bundle':str(self.app),'helper':str(self.helper)}))
        self.registration=[{'bundle':str(p),'exitCode':0} for p in [self.app,self.helper]]
        for name in ['workspace.png','ui-report.json','app.log','products.json']:(self.root/name).write_text('evidence')
    def tearDown(self):self.temp.cleanup()
    def test_positive_keeps_evidence(self):
        self.assertEqual(len(remove_staged_bundles(self.root,self.registration,retirement_verified=True)),2)
        self.assertFalse(self.app.exists());self.assertFalse(self.helper.exists())
        for name in ['workspace.png','ui-report.json','app.log','products.json']:self.assertTrue((self.root/name).exists())
    def test_live_or_unconfirmed_is_not_deleted(self):
        with self.assertRaises(RuntimeError):remove_staged_bundles(self.root,self.registration,retirement_verified=False)
        self.assertTrue(self.app.exists())
    def test_failed_registration_is_not_deleted(self):
        self.registration[1]['exitCode']=1
        with self.assertRaises(RuntimeError):remove_staged_bundles(self.root,self.registration,retirement_verified=True)
        self.assertTrue(self.app.exists())
    def test_symlink_cannot_escape_or_partially_delete(self):
        (self.helper/'dummy').unlink();self.helper.rmdir()
        outside=self.root/'unrelated';outside.mkdir();(outside/'data').write_text('keep')
        self.helper.symlink_to(outside,target_is_directory=True)
        with self.assertRaises(RuntimeError):remove_staged_bundles(self.root,self.registration,retirement_verified=True)
        self.assertTrue(self.app.exists());self.assertTrue((outside/'data').exists())
    def test_wrong_manifest_is_not_deleted(self):
        (self.root/'fixture-bundle.json').write_text('{}')
        with self.assertRaises(RuntimeError):remove_staged_bundles(self.root,self.registration,retirement_verified=True)
        self.assertTrue(self.app.exists())
    def test_other_root_is_not_deleted(self):
        with tempfile.TemporaryDirectory(prefix='unrelated.',dir='/private/tmp') as other:
            with self.assertRaises(RuntimeError):remove_staged_bundles(Path(other),self.registration,retirement_verified=True)
        self.assertTrue(self.app.exists())

if __name__=='__main__':unittest.main()
