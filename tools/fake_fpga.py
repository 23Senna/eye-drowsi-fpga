"""Serial-port stand-in for --dry-run: the image-upload protocol, bit-exact integer CNN and DrowsyRef.

Timing is a model, not a measurement: every byte costs 10 bits / baud on the wire, and each FPGA
reply is held back by usb_ms (the FTDI latency timer flushes short packets after 16 ms by default,
1 ms when the driver setting is lowered). Use it to compare settings and to exercise the live loop
without a board; real numbers come from the board run.
"""
import binascii
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'integration/scripts'))
from drowsy_ref import DrowsyRef, state_name  # noqa: E402
from live_audit import Reference  # noqa: E402


class FakeFpga:
    def __init__(self, baud=1000000, usb_ms=1.0, cycles=702, timeout=0.05):
        self.byte_s, self.usb_s, self.cycles, self.timeout = 10 / baud, usb_ms / 1000, cycles, timeout
        self.reference, self.fsm = Reference(), DrowsyRef()
        self.rx_done = 0.0          # when the FPGA has received everything written so far
        self.out = []               # (ready_time, byte)
        self.cond = threading.Condition()
        self.line = bytearray()
        self.payload = None         # bytearray while a LOAD payload is expected
        self.load_id = self.frame = self.last_id = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def close(self):
        pass

    def _reply(self, text, start, extra_s=0.0):
        data = (text + '\r\n').encode('ascii')
        t = max(start + extra_s, self.out[-1][0] - self.usb_s if self.out else 0)
        for i, b in enumerate(data):
            self.out.append((t + (i + 1) * self.byte_s + self.usb_s, bytes([b])))

    def write(self, data):
        with self.cond:
            self.rx_done = max(self.rx_done, time.perf_counter()) + len(data) * self.byte_s
            for b in data:
                self._byte(b)
            self.cond.notify_all()
        return len(data)

    def _byte(self, b):
        if self.payload is not None:
            self.payload.append(b)
            if len(self.payload) == 578:
                pixels, crc = bytes(self.payload[:576]), int.from_bytes(self.payload[576:], 'big')
                self.payload = None
                if binascii.crc_hqx(pixels, 0xffff) == crc:
                    self.frame = (self.load_id, pixels)
                    self._reply(f'OK FRAME {self.load_id}', self.rx_done)
                else:
                    self.frame = None
                    self._reply('ERR CRC', self.rx_done)
            return
        if b != 0x0A:
            self.line.append(b)
            return
        cmd = self.line.decode('ascii', 'replace').strip().split()
        self.line.clear()
        if len(cmd) == 2 and cmd[0] == 'LOAD':
            fid = int(cmd[1], 16)
            if fid == self.last_id:
                self._reply('ERR ID', self.rx_done)
                return
            self.load_id, self.frame, self.payload = fid, None, bytearray()
            self._reply(f'READY {fid}', self.rx_done)
        elif len(cmd) == 2 and cmd[0] == 'RUN_FRAME':
            fid = int(cmd[1], 16)
            if self.frame is None:
                self._reply('ERR NOFRAME', self.rx_done)
            elif self.frame[0] != fid:
                self._reply('ERR ID', self.rx_done)
            else:
                pixels, self.frame, self.last_id = self.frame[1], None, fid
                l0, l1 = self.reference.logits(pixels)
                closed = int(l0 >= l1)
                state = self.fsm.step(closed)['state']
                self._reply('OK RUN', self.rx_done)
                self._reply(f'RESULT source=UPLOAD slot=0 class={"CLOSED" if closed else "OPEN"} '
                            f'warning={state_name(state)} logit0={l0} logit1={l1} cycles={self.cycles} '
                            f'us={(self.cycles + 50) // 100} frame_id={fid}', self.rx_done, self.cycles / 1e8)
        else:
            self._reply('ERR CMD', self.rx_done)

    def read(self, size=1):
        # time.sleep is high-resolution on Windows (Python >= 3.11); Condition.wait ticks at 15.6 ms.
        deadline = time.perf_counter() + self.timeout
        got = b''
        while len(got) < size:
            now = time.perf_counter()
            with self.cond:
                if self.out and self.out[0][0] <= now:
                    got += self.out.pop(0)[1]
                    continue
                nxt = self.out[0][0] if self.out else deadline
            if now >= deadline:
                break
            time.sleep(max(min(nxt, deadline) - now, 0))
        return got

    @property
    def in_waiting(self):
        now = time.perf_counter()
        return sum(1 for t, _ in self.out if t <= now)

    def reset_input_buffer(self):
        self.out.clear()


def main(argv=None):
    """Model-only link benchmark: python tools/fake_fpga.py --baud 115200 --usb-ms 16"""
    import argparse
    import statistics
    from uart_cli import run_image
    parser = argparse.ArgumentParser(description=main.__doc__)
    parser.add_argument('--baud', type=int, default=1000000)
    parser.add_argument('--usb-ms', type=float, default=1.0)
    parser.add_argument('--frames', type=int, default=20)
    args = parser.parse_args(argv)
    words = (ROOT / 'ml/export/images.mem').read_text().split()
    port, rows = FakeFpga(args.baud, args.usb_ms), []
    for i in range(args.frames):
        slot = i % 16
        pixels = bytes(int(w, 16) for w in words[slot * 1024:slot * 1024 + 576])
        stages = {}
        run_image(port, pixels, 100 + i, emit=lambda line: None, stages=stages)
        rows.append(stages)
    med = {k: statistics.median(r[k] for r in rows) for k in rows[0]}
    print(f"baud={args.baud} usb={args.usb_ms}ms  READY {med['ready']:.1f}  OK FRAME {med['frame']:.1f}  "
          f"OK RUN {med['run']:.1f}  RESULT {med['result']:.1f} ms (cumulative, median of {args.frames})")


if __name__ == '__main__':
    main()
