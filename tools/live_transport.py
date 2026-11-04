"""Latest-frame mailbox and single-transaction UART worker for live capture."""
import threading
import time
from uart_cli import run_image


class Mailbox:
    def __init__(self):
        self.lock = threading.Lock()
        self.item = None
        self.replaced = 0

    def put(self, pixels, captured, sequence, label=None):
        pixels = bytes(pixels)
        if len(pixels) != 576:
            raise ValueError('Expected 576 uint8 pixels')
        with self.lock:
            if self.item is not None:
                self.replaced += 1
            self.item = (pixels, captured, sequence, label)

    def take(self, now, max_age):
        with self.lock:
            item, self.item = self.item, None
        return item if item is not None and 0 <= now-item[1] <= max_age else None

    def clear(self):
        with self.lock:
            self.item = None


class Transport:
    def __init__(self, port_factory, emit, fps=10, frame_id=1000, max_age=0.25, audit=None):
        self.port_factory, self.emit = port_factory, emit
        self.audit=audit
        self.period, self.frame_id, self.max_age = 1/fps, frame_id, max_age
        self.mailbox = Mailbox()
        self.stop = threading.Event()
        self.enabled = threading.Event()
        self.ready = threading.Event()
        self.busy = threading.Event()
        self.error = None
        self.thread = threading.Thread(target=self._run, daemon=True)

    def pause(self):
        self.enabled.clear()
        self.mailbox.clear()

    def _run(self):
        try:
            with self.port_factory() as port:
                self.ready.set()
                self.emit({'event':'serial_ready'})
                next_send = 0
                previous_capture = None
                previous_sequence = None
                while not self.stop.is_set():
                    if not self.enabled.is_set():
                        self.stop.wait(0.01)
                        continue
                    now = time.monotonic()
                    if now < next_send:
                        self.stop.wait(min(next_send-now,0.01))
                        continue
                    item = self.mailbox.take(now,self.max_age)
                    if item is None:
                        self.stop.wait(0.005)
                        continue
                    if not self.enabled.is_set():
                        continue
                    pixels,captured,sequence,label = item
                    if sequence == previous_sequence:
                        continue
                    if self.frame_id > 65535:
                        raise RuntimeError('Frame IDs exhausted; reset board and start a new session')
                    started = time.monotonic()
                    self.busy.set()
                    result = run_image(port,pixels,self.frame_id,timeout=2,
                                       emit=lambda line:self.emit({'event':'serial','line':line}))
                    finished = time.monotonic()
                    self.busy.clear()
                    audit={} if self.audit is None else self.audit(self.frame_id,pixels,result)
                    self.emit({'event':'result','result':result,'capture_sequence':sequence,
                               'operator_label':label,**audit,
                               'captured_monotonic':captured,'sent_monotonic':started,
                               'result_monotonic':finished,'roundtrip_ms':(finished-started)*1000,
                               'capture_to_result_ms':(finished-captured)*1000,
                               'capture_interval_ms':None if previous_capture is None else (captured-previous_capture)*1000,
                               'replaced_frames':self.mailbox.replaced})
                    if audit.get('golden_match') is False:
                        raise RuntimeError('FPGA logits disagree with integer golden; exact input saved, transmission stopped')
                    previous_capture = captured
                    previous_sequence = sequence
                    self.frame_id += 1
                    next_send = max(started+self.period,finished)
        except Exception as exc:
            self.error = str(exc)
            self.pause()
            self.emit({'event':'error','message':self.error})
        finally:
            self.ready.clear()
            self.busy.clear()

    def close(self):
        self.pause()
        self.stop.set()
        self.thread.join(timeout=7)
        if self.thread.is_alive():
            raise RuntimeError('Serial transaction still draining; reset board before reconnecting')
