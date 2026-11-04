from pathlib import Path
import tempfile
import unittest
from live_audit import ROOT, Reference, Audit


class AuditTests(unittest.TestCase):
    def test_all_exported_logit_pairs(self):
        ref=Reference()
        values=bytes(int(s,16) for s in (ROOT/'ml/export/images.mem').read_text().split())
        for line in (ROOT/'ml/export/expected.txt').read_text().splitlines()[1:]:
            i,label,pred,l0,l1=map(int,line.split())
            self.assertEqual(ref.logits(values[i*1024:i*1024+576]),(l0,l1))

    def test_exact_bytes_and_mismatch_detection(self):
        with tempfile.TemporaryDirectory() as d:
            audit=Audit(d);pixels=bytes(range(256))*2+bytes(range(64))
            l0,l1=audit.reference.logits(pixels)
            result={'logit0':l0,'logit1':l1}
            info=audit(123,pixels,result)
            self.assertTrue(info['golden_match'])
            self.assertEqual(Path(info['input_raw']).read_bytes(),pixels)
            wrong=audit(124,pixels,{'logit0':l0+1,'logit1':l1})
            self.assertFalse(wrong['golden_match'])
            with self.assertRaises(FileExistsError):audit(123,pixels,result)
            with self.assertRaises(ValueError):audit.reference.logits(b'bad')
