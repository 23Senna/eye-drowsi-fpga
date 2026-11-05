import queue
import time
import unittest
from live_transport import Mailbox, Transport, clock


class Port:
    def __init__(self, fail=False):
        self.data=bytearray();self.loaded=0;self.mode='command';self.writes=[];self.closed=False;self.fail=fail
    def __enter__(self):return self
    def __exit__(self,*args):self.closed=True
    def write(self,data):
        self.writes.append(data)
        if self.mode=='payload':
            if len(data)!=578:raise RuntimeError('bad payload length')
            self.mode='command';reply=f'OK FRAME {self.loaded}\n'
        elif data.startswith(b'LOAD '):
            self.loaded=int(data[5:],16);self.mode='payload'
            reply='ERR MODE\n' if self.fail else f'READY {self.loaded}\n'
        elif data.startswith(b'RUN_FRAME '):
            reply=f'OK RUN\nRESULT source=UPLOAD slot=0 class=OPEN warning=AWAKE logit0=492 logit1=727 cycles=7996 us=79 frame_id={self.loaded}\n'
        else:raise RuntimeError('bad command')
        self.data.extend(reply.encode());return len(data)
    def read(self,n):
        b=self.data[:n];del self.data[:n];return bytes(b)


class LiveTests(unittest.TestCase):
    def test_latest_and_freshness(self):
        m=Mailbox();m.put(bytes([1])*576,10,1);m.put(bytes([2])*576,10.1,2)
        self.assertEqual(m.replaced,1)
        self.assertEqual(m.take(10.2,0.25)[2],2)
        self.assertIsNone(m.take(10.2,0.25))
        m.put(bytes(576),10,3);self.assertIsNone(m.take(11,0.25))
        m.put(bytes(576),12,4);self.assertIsNone(m.take(11,0.25))
        with self.assertRaises(ValueError):m.put(b'',10,5)

    def test_persistent_port_ids_pause_and_no_replay(self):
        p=Port();events=queue.Queue();calls=[]
        def factory():calls.append(1);return p
        w=Transport(factory,events.put,fps=100,frame_id=500)
        w.thread.start();self.assertTrue(w.ready.wait(1));w.enabled.set()
        try:
            for sequence in [10,11]:
                w.mailbox.put(bytes(576),clock(),sequence)
                deadline=clock()+1
                while clock()<deadline:
                    e=events.get(timeout=1)
                    if e['event']=='result':break
                self.assertEqual(e['capture_sequence'],sequence)
                self.assertEqual(e['result']['frame_id'],490+sequence)
            time.sleep(0.04)
            self.assertEqual(len(p.writes),6)
            w.mailbox.put(bytes(576),clock(),11)
            time.sleep(0.03)
            self.assertEqual(len(p.writes),6)
            w.mailbox.put(bytes(576),clock(),12);w.pause()
            self.assertIsNone(w.mailbox.item)
        finally:w.close()
        self.assertEqual(calls,[1]);self.assertTrue(p.closed)

    def test_error_stops_without_retry(self):
        p=Port(fail=True);events=queue.Queue();w=Transport(lambda:p,events.put)
        w.thread.start();self.assertTrue(w.ready.wait(1));w.enabled.set()
        w.mailbox.put(bytes(576),clock(),1)
        w.thread.join(1);w.close()
        self.assertEqual(w.error,'ERR MODE');self.assertEqual(len(p.writes),1)

    def test_exhausted_id_does_not_send(self):
        p=Port();w=Transport(lambda:p,lambda e:None,frame_id=65536)
        w.thread.start();self.assertTrue(w.ready.wait(1));w.enabled.set()
        w.mailbox.put(bytes(576),clock(),1);w.thread.join(1);w.close()
        self.assertIn('exhausted',w.error);self.assertEqual(p.writes,[])

    def test_golden_mismatch_stops_and_keeps_fpga_result(self):
        p=Port();events=queue.Queue()
        w=Transport(lambda:p,events.put,audit=lambda *a:{'golden_match':False})
        w.thread.start();self.assertTrue(w.ready.wait(1));w.enabled.set()
        w.mailbox.put(bytes(576),clock(),1,'CLOSED')
        w.thread.join(1);w.close()
        self.assertIn('disagree',w.error);self.assertEqual(len(p.writes),3)
        rows=[]
        while not events.empty():rows.append(events.get())
        event=next(e for e in rows if e['event']=='result')
        self.assertEqual(event['operator_label'],'CLOSED')
        self.assertEqual(event['result']['eye_class'],'OPEN')


if __name__=='__main__':unittest.main()
