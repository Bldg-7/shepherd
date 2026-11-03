"""Inert receipt fixtures, never starts a binary or a core."""
from pathlib import Path
import copy
import json
import tempfile
import unittest
import candidate_artifact as artifact


class CandidateArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='hc-candidate-test.')
        self.root = Path(self.temp.name).resolve()
        r, base = artifact.recipes()
        (self.root/'herdr-core').write_bytes(b'inert unit fixture')
        self.value = {'schema':1,'variant':r['variant'],'officialRelease':False,
            'recipeSHA256':artifact.digest(artifact.RECIPE),
            'builderSHA256':artifact.digest(artifact.HERE/'backport/build-candidate.py'),
            'validatorSHA256':artifact.digest(Path(artifact.__file__)),
            'binary':'herdr-core','binarySHA256':artifact.digest(self.root/'herdr-core'),
            'toolchain':{'rustc':'rustc 1.95.0 (synthetic)','zig':base['zigVersion'],'zigSHA256':base['zigBinarySHA256']},'checks':{}}
        for name in artifact.CHECKS:
            log=self.root/(name+'.log'); log.write_text('inert fixture, not build evidence')
            self.value['checks'][name]={'passed':True,'testCount':1,'logSHA256':artifact.digest(log)}
        self.path=self.root/'receipt.json'; self.save()

    def tearDown(self): self.temp.cleanup()
    def save(self): self.path.write_text(json.dumps(self.value))
    def select(self): return artifact.select(self.path)

    def test_explicit_local_receipt(self):
        binary, receipt=self.select()
        self.assertEqual(binary,self.root/'herdr-core')
        self.assertFalse(receipt['officialRelease'])

    def test_provenance_is_pinned(self):
        original=copy.deepcopy(self.value)
        for field in ['variant','recipeSHA256','builderSHA256','validatorSHA256']:
            self.value=copy.deepcopy(original); self.value[field]='changed'; self.save()
            with self.subTest(field=field),self.assertRaises(ValueError):self.select()

    def test_not_official(self):
        self.value['officialRelease']=True;self.save()
        with self.assertRaises(ValueError):self.select()

    def test_missing_failed_and_zero_checks(self):
        original=copy.deepcopy(self.value)
        for name in artifact.CHECKS:
            self.value=copy.deepcopy(original); self.value['checks'][name]['passed']=False;self.save()
            with self.subTest(name=name),self.assertRaises(ValueError):self.select()
        self.value=copy.deepcopy(original); del self.value['checks']['notices'];self.save()
        with self.assertRaises(ValueError):self.select()
        for count in [0,None,True,'10']:
            self.value=copy.deepcopy(original);self.value['checks']['core-library-tests']['testCount']=count;self.save()
            with self.subTest(count=count),self.assertRaises(ValueError):self.select()

    def test_log_changed(self):
        (self.root/'build.log').write_text('changed')
        with self.assertRaises(ValueError):self.select()

    def test_wrong_toolchain(self):
        original=copy.deepcopy(self.value)
        for name,value in [('rustc','rustc 1.94.1'),('zig','0.17.0'),('zigSHA256','0'*64)]:
            self.value=copy.deepcopy(original);self.value['toolchain'][name]=value;self.save()
            with self.subTest(name=name),self.assertRaises(ValueError):self.select()

    def test_binary_name_and_bytes(self):
        self.value['binary']='../escape';self.save()
        with self.assertRaises(ValueError):self.select()
        self.value['binary']='herdr-core';self.save()
        (self.root/'herdr-core').write_bytes(b'changed')
        with self.assertRaises(ValueError):self.select()

    def test_binary_link_and_empty(self):
        file=self.root/'herdr-core'; file.rename(self.root/'other');file.symlink_to(self.root/'other')
        with self.assertRaises(ValueError):self.select()
        file.unlink();file.write_bytes(b'')
        with self.assertRaises(ValueError):self.select()


if __name__=='__main__':unittest.main()
