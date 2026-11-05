import binascii
import time
import unittest
from pathlib import Path
from fake_fpga import FakeFpga
from uart_cli import run_image, write_all, Lines

ROOT = Path(__file__).resolve().parents[1]


class FakeFpgaTest(unittest.TestCase):
    def setUp(self):
        self.words = (ROOT / 'ml/export/images.mem').read_text().split()
        rows = (ROOT / 'ml/export/expected.txt').read_text().splitlines()[1:]
        self.expected = {int(r.split()[0]): tuple(map(int, r.split()[3:5])) for r in rows}

    def pixels(self, slot):
        return bytes(int(w, 16) for w in self.words[slot * 1024:slot * 1024 + 576])

    def test_golden_logits_and_stages(self):
        port = FakeFpga(baud=6250000, usb_ms=0)
        for slot in range(16):
            stages = {}
            r = run_image(port, self.pixels(slot), 10 + slot, emit=lambda line: None, stages=stages)
            self.assertEqual((r['logit0'], r['logit1']), self.expected[slot])
            self.assertEqual(r['frame_id'], 10 + slot)
            self.assertEqual(r['eye_class'], 'CLOSED' if r['logit0'] >= r['logit1'] else 'OPEN')
            self.assertLessEqual(stages['ready'], stages['frame'])
            self.assertLessEqual(stages['run'], stages['result'])

    def test_crc_error_and_id_reuse(self):
        port = FakeFpga(baud=6250000, usb_ms=0)
        lines = Lines(port)
        write_all(port, b'LOAD 0001\n')
        self.assertEqual(lines.read(time.monotonic() + 1), 'READY 1')
        px = self.pixels(0)
        write_all(port, px + ((binascii.crc_hqx(px, 0xffff) ^ 1).to_bytes(2, 'big')))
        self.assertEqual(lines.read(time.monotonic() + 1), 'ERR CRC')
        run_image(port, px, 2, emit=lambda line: None)
        with self.assertRaises(RuntimeError):
            run_image(port, px, 2, emit=lambda line: None)


if __name__ == '__main__':
    unittest.main()
