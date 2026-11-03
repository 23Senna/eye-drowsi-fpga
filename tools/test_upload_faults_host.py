import binascii
import io
import unittest
from check_upload_faults import Check, fault


class Port:
    def __init__(self,replies):
        self.replies=list(replies);self.data=bytearray();self.writes=[]
    def write(self,data):
        self.writes.append(bytes(data))
        if self.replies:self.data.extend(self.replies.pop(0))
        return len(data)
    def read(self,n):
        data=self.data[:n];del self.data[:n];return bytes(data)


class FaultTests(unittest.TestCase):
    def test_crc_fault_and_no_run_acceptance(self):
        p=Port([b'READY 100\n',b'ERR CRC\n',b'ERR NOFRAME\n'])
        pixels=bytes(range(256))*2+bytes(64)
        fault(Check(p,io.StringIO()),'crc',pixels,100)
        self.assertEqual(p.writes[1][:576],pixels)
        self.assertEqual(int.from_bytes(p.writes[1][-2:],'big'),binascii.crc_hqx(pixels,0xffff)^1)
        self.assertEqual(p.writes[2],b'RUN_FRAME 0064\n')

    def test_timeout_sends_only_partial_frame(self):
        p=Port([b'READY 100\n',b'ERR TIMEOUT\n',b'ERR NOFRAME\n'])
        fault(Check(p,io.StringIO()),'timeout',bytes(576),100)
        self.assertEqual(len(p.writes[1]),64)

    def test_unexpected_result_fails(self):
        p=Port([b'READY 100\n',b'RESULT unexpected\n'])
        with self.assertRaises(RuntimeError):fault(Check(p,io.StringIO()),'crc',bytes(576),100)

    def test_timeout_is_not_accepted_as_reset(self):
        p=Port([b'READY 100\n',b'ERR TIMEOUT\n'])
        with self.assertRaises(RuntimeError):
            fault(Check(p,io.StringIO()),'reset',bytes(576),100,lambda check:None)


if __name__=='__main__':unittest.main()
