import unittest
from uart_cli import Lines, parse_result, run_slot
import time

LINE='RESULT source=PC slot=3 class=OPEN warning=AWAKE logit0=-6948 logit1=11172 cycles=37290 us=372'


class Port:
    def __init__(self, responses):
        self.responses=list(responses);self.data=bytearray();self.writes=[]
    def write(self, data):
        self.writes.append(data)
        if self.responses:self.data.extend(self.responses.pop(0))
    def read(self, n):
        data=self.data[:n];del self.data[:n];return bytes(data)


class HostTests(unittest.TestCase):
    def test_run_and_interleaved_monitoring(self):
        board=LINE.replace('source=PC','source=BOARD')
        p=Port([(board+'\r\nOK SLOT 3\r\n').encode(),('OK RUN\r\n'+board+'\r\n'+LINE+'\r\n').encode()])
        output=[];r=run_slot(p,3,emit=output.append)
        self.assertEqual(p.writes,[b'SLOT 3\n',b'RUN\n'])
        self.assertEqual(r['logit0'],-6948);self.assertEqual(len(output),5)
    def test_errors_do_not_retry(self):
        for message in ['ERR MODE','ERR BUSY','ERR RANGE']:
            p=Port([(message+'\n').encode()])
            with self.assertRaises(RuntimeError):run_slot(p,3,emit=lambda _:None)
            self.assertEqual(len(p.writes),1)
    def test_timeout_does_not_repeat_run(self):
        p=Port([b'OK SLOT 3\n',b'OK RUN\n'])
        with self.assertRaises(TimeoutError):run_slot(p,3,0.01,emit=lambda _:None)
        self.assertEqual(p.writes,[b'SLOT 3\n',b'RUN\n'])
    def test_partial_line_timeout_keeps_buffer(self):
        p=Port([]);p.data.extend(b'OK SL');reader=Lines(p)
        with self.assertRaises(TimeoutError):reader.read(time.monotonic()+0.001)
        p.data.extend(b'OT 3\r\n');self.assertEqual(reader.read(time.monotonic()+1),'OK SLOT 3')
    def test_validation(self):
        self.assertEqual(parse_result(LINE)['cycles'],37290)
        for line in [LINE.replace('slot=3','slot=16'),LINE.replace('-6948','-2147483649'),'RESULT broken']:
            with self.assertRaises(ValueError):parse_result(line)
        with self.assertRaises(ValueError):run_slot(Port([]),16)


if __name__=='__main__':unittest.main()
