import binascii
from pathlib import Path
import tempfile
import unittest
from uart_cli import load_pixels, parse_result, run_image, write_all

RESULT = ('RESULT source=UPLOAD slot=0 class=OPEN warning=AWAKE '
          'logit0=492 logit1=727 cycles=37290 us=372 frame_id=4660')


class UploadPort:
    def __init__(self, replies, limit=13):
        self.replies = list(replies)
        self.data = bytearray()
        self.parts = bytearray()
        self.stages = []
        self.limit = limit

    def write(self, data):
        size = min(len(data), self.limit)
        self.parts.extend(data[:size])
        expected_length = 578 if len(self.stages) == 1 else None
        complete = (len(self.parts) == expected_length if expected_length else self.parts.endswith(b'\n'))
        if complete:
            self.stages.append(bytes(self.parts))
            self.parts.clear()
            if self.replies:
                self.data.extend(self.replies.pop(0))
        return size

    def read(self, n):
        data = self.data[:n]
        del self.data[:n]
        return bytes(data)


class UploadTests(unittest.TestCase):
    def test_binary_upload_crc_partial_writes_and_result(self):
        pixels = bytes(range(256))*2 + bytes(range(64))
        port = UploadPort([b'READY 4660\r\n', b'OK FRAME 4660\r\n',
                           ('OK RUN\r\n'+RESULT+'\r\n').encode()])
        self.assertEqual(run_image(port,pixels,0x1234,emit=lambda _:None)['frame_id'],4660)
        self.assertEqual(port.stages[0],b'LOAD 1234\n')
        self.assertEqual(port.stages[1],pixels+binascii.crc_hqx(pixels,0xffff).to_bytes(2,'big'))
        self.assertEqual(port.stages[2],b'RUN_FRAME 1234\n')
        self.assertEqual(binascii.crc_hqx(b'123456789',0xffff),0x29b1)

    def test_crc_error_never_runs(self):
        port=UploadPort([b'READY 4660\n',b'ERR CRC\n'])
        with self.assertRaisesRegex(RuntimeError,'ERR CRC'):
            run_image(port,bytes(576),4660,emit=lambda _:None)
        self.assertEqual(len(port.stages),2)

    def test_timeout_never_retries(self):
        port=UploadPort([b'READY 4660\n',b'OK FRAME 4660\n',b'OK RUN\n'])
        with self.assertRaises(TimeoutError):
            run_image(port,bytes(576),4660,timeout=0.01,emit=lambda _:None)
        self.assertEqual(len(port.stages),3)

    def test_wrong_identity_rejected(self):
        for replies in [[b'READY 3\n'], [b'READY 4660\n',b'OK FRAME 4660\n',
                ('OK RUN\n'+RESULT.replace('frame_id=4660','frame_id=3')+'\n').encode()]]:
            with self.assertRaises(ValueError):
                run_image(UploadPort(replies),bytes(576),4660,emit=lambda _:None)

    def test_result_schema_and_validation_before_write(self):
        for record in [RESULT.replace(' frame_id=4660',''),RESULT.replace('4660','65536'),
                       RESULT.replace('source=UPLOAD','source=PC')]:
            with self.assertRaises(ValueError):parse_result(record)
        for pixels,frame_id in [(b'',1),(bytes(577),1),(bytes(576),-1),(bytes(576),65536)]:
            port=UploadPort([])
            with self.assertRaises(ValueError):run_image(port,pixels,frame_id)
            self.assertEqual(port.stages,[])
        class Stalled:
            def write(self,data):return 0
        with self.assertRaises(OSError):write_all(Stalled(),b'abc')

    def test_exact_input_formats(self):
        with tempfile.TemporaryDirectory() as directory:
            raw=Path(directory)/'eye.raw'
            pixels=bytes(range(256))*2+bytes(range(64))
            raw.write_bytes(pixels)
            self.assertEqual(load_pixels(raw),pixels)
            with self.assertRaises(ValueError):load_pixels(raw,0)
            mem=Path(directory)/'images.mem'
            mem.write_text('00\n'*1024+'\n'.join(f'{v:02x}' for v in pixels)+'\n00'*448+'\n00'*14336)
            self.assertEqual(load_pixels(mem,1),pixels)
            with self.assertRaises(ValueError):load_pixels(mem)
            raw.write_bytes(b'invalid')
            with self.assertRaises(ValueError):load_pixels(raw)

    def test_png_pixels_and_rgb_resize(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'eye.png'
            pixels=bytes(range(256))*2+bytes(range(64))
            Image.frombytes('L',(24,24),pixels).save(path)
            self.assertEqual(load_pixels(path),pixels)
            Image.new('RGB',(48,48),(73,73,73)).save(path)
            self.assertEqual(load_pixels(path),bytes([73])*576)


if __name__=='__main__':unittest.main()
