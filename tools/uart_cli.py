"""Control and monitor the Basys3 CNN over a line-oriented 115200 8N1 UART."""
import argparse
import binascii
from pathlib import Path
import re
import sys
import time

RESULT = re.compile(
    r"RESULT source=(BOARD|PC|SEQ|UPLOAD) slot=(\d+) class=(OPEN|CLOSED) "
    r"warning=(AWAKE|DROWSY|MICROSLEEP) logit0=(-?\d+) logit1=(-?\d+) cycles=(\d+) us=(\d+)"
    r"(?: frame_id=(\d+))?$")


def parse_result(line):
    match = RESULT.fullmatch(line)
    if not match:
        raise ValueError("Malformed RESULT: " + line)
    source, slot, eye_class, warning, l0, l1, cycles, us, frame_id = match.groups()
    values = dict(source=source, slot=int(slot), eye_class=eye_class, warning=warning,
                  logit0=int(l0), logit1=int(l1), cycles=int(cycles), us=int(us))
    if not 0 <= values['slot'] <= 15:
        raise ValueError('Result slot outside 0..15')
    if not all(-(1 << 31) <= values[k] < (1 << 31) for k in ('logit0', 'logit1')):
        raise ValueError('Result logits outside int32')
    if not all(0 <= values[k] < (1 << 32) for k in ('cycles', 'us')):
        raise ValueError('Result timing outside uint32')
    if source == 'UPLOAD':
        if frame_id is None or not 0 <= int(frame_id) <= 65535:
            raise ValueError('Upload result requires uint16 frame_id')
        values['frame_id'] = int(frame_id)
    elif frame_id is not None:
        raise ValueError('Only upload results carry frame_id')
    return values


class Lines:
    def __init__(self, port):
        self.port = port
        self.pending = bytearray()

    def read(self, deadline):
        while time.monotonic() < deadline:
            byte = self.port.read(1)
            if not byte:
                continue
            if byte == b'\n':
                line = bytes(self.pending).rstrip(b'\r')
                self.pending.clear()
                try:
                    return line.decode('ascii')
                except UnicodeDecodeError as exc:
                    raise ValueError('Non-ASCII serial response') from exc
            self.pending.extend(byte)
            if len(self.pending) > 256:
                self.pending.clear()
                raise ValueError('Serial line exceeds 256 bytes')
        raise TimeoutError('UART transaction timed out; RUN was not retried')


def run_slot(port, slot, timeout=2.0, emit=print):
    """Send one SLOT and one RUN, never automatically retry either operation."""
    if not 0 <= slot <= 15:
        raise ValueError('slot must be 0..15')
    reader = Lines(port)

    def next_line(deadline):
        while True:
            line = reader.read(deadline)
            if not line:
                continue
            emit(line)
            if line.startswith('ERR '):
                raise RuntimeError(line)
            if line.startswith('RESULT '):
                parse_result(line)
            return line

    port.write(f'SLOT {slot}\n'.encode('ascii'))
    deadline = time.monotonic() + timeout
    while True:
        line = next_line(deadline)
        if line == f'OK SLOT {slot}':
            break
        if not line.startswith('RESULT '):
            raise ValueError('Unexpected SLOT response: ' + line)
    port.write(b'RUN\n')
    deadline = time.monotonic() + timeout
    acknowledged = False
    while True:
        line = next_line(deadline)
        if line == 'OK RUN':
            acknowledged = True
        elif line.startswith('RESULT '):
            result = parse_result(line)
            if acknowledged and result['source'] == 'PC' and result['slot'] == slot:
                return result
        else:
            raise ValueError('Unexpected RUN response: ' + line)


def write_all(port, data):
    """Handle partial writes without replaying an already accepted byte."""
    offset = 0
    while offset < len(data):
        written = port.write(data[offset:])
        if written is None or written <= 0 or written > len(data)-offset:
            raise OSError('UART write did not make valid progress')
        offset += written


def run_image(port, pixels, frame_id, timeout=2.0, emit=print):
    """Upload once, validate ACKs, run once; never retry after uncertain delivery."""
    pixels = bytes(pixels)
    if len(pixels) != 576 or not 0 <= frame_id <= 65535:
        raise ValueError('Expected 576 pixels and a uint16 frame_id')
    reader = Lines(port)

    def response(expected):
        deadline = time.monotonic() + timeout
        while True:
            line = reader.read(deadline)
            if not line:
                continue
            emit(line)
            if line.startswith('ERR '):
                raise RuntimeError(line)
            if line == expected:
                return
            if line.startswith('RESULT '):
                parse_result(line)
            else:
                raise ValueError('Unexpected upload response: ' + line)

    write_all(port, f'LOAD {frame_id:04X}\n'.encode('ascii'))
    response(f'READY {frame_id}')
    crc = binascii.crc_hqx(pixels, 0xffff)
    write_all(port, pixels + crc.to_bytes(2, 'big'))
    response(f'OK FRAME {frame_id}')
    write_all(port, f'RUN_FRAME {frame_id:04X}\n'.encode('ascii'))
    response('OK RUN')
    deadline = time.monotonic() + timeout
    while True:
        line = reader.read(deadline)
        if not line:
            continue
        emit(line)
        if line.startswith('ERR '):
            raise RuntimeError(line)
        result = parse_result(line)
        if result['source'] == 'UPLOAD':
            if result['frame_id'] != frame_id:
                raise ValueError('Mismatched upload frame_id')
            return result


def load_pixels(path, slot=None):
    """Raw bytes or exported hex values are exact; image files must be eye crops."""
    path = Path(path)
    if path.suffix.lower() == '.mem':
        values = bytes(int(x, 16) for x in path.read_text().split())
        if slot is not None:
            if not 0 <= slot < 16 or len(values) != 16384:
                raise ValueError('--slot needs a 16-slot images.mem')
            return values[slot*1024:slot*1024+576]
        if len(values) != 576:
            raise ValueError('Use --slot for a padded images.mem')
        return values
    if slot is not None:
        raise ValueError('--slot only applies to .mem input')
    if path.suffix.lower() in ('.raw', '.bin'):
        data = path.read_bytes()
        if len(data) != 576:
            raise ValueError('Raw image must contain exactly 576 bytes')
        return data
    try:
        from PIL import Image
    except ImportError as exc:
        raise ValueError('PNG/JPEG input needs Pillow; see tools/requirements-image.txt') from exc
    with Image.open(path) as im:
        return im.convert('L').resize((24, 24), Image.Resampling.BOX).tobytes()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', help='Serial port, e.g. COM4')
    parser.add_argument('--baud', type=int, default=115200)
    parser.add_argument('--timeout', type=float, default=2.0)
    parser.add_argument('--quiet', action='store_true',
                        help='Print only RESULT and ERR lines')
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('ports', help='List available serial ports')
    run = sub.add_parser('run', help='Select a slot, run once and print its result')
    run.add_argument('--slot', type=int, required=True, choices=range(16), metavar='0..15')
    upload = sub.add_parser('upload', help='Upload an eye crop and run once (SW9 up)')
    upload.add_argument('--image', required=True, help='576-byte .raw/.bin, .mem, or eye-crop PNG/JPEG')
    upload.add_argument('--frame-id', required=True, type=int, metavar='0..65535')
    upload.add_argument('--slot', type=int, choices=range(16), help='Extract a slot from images.mem on the PC')
    sub.add_parser('monitor', help='Print results/replies from all board modes until Ctrl+C')
    args = parser.parse_args(argv)
    if args.timeout <= 0 or args.baud <= 0:
        parser.error('baud and timeout must be positive')
    if args.command == 'upload' and not 0 <= args.frame_id <= 65535:
        parser.error('frame-id must be 0..65535')
    try:
        import serial
        from serial.tools import list_ports
    except ImportError:
        print('Install the host dependency: python -m pip install -r tools/requirements.txt', file=sys.stderr)
        return 1
    if args.command == 'ports':
        for port in list_ports.comports():
            print(port.device, port.description)
        return 0
    if not args.port:
        parser.error('--port is required for run/monitor')
    try:
        with serial.Serial(args.port, args.baud, bytesize=serial.EIGHTBITS,
                           parity=serial.PARITY_NONE, stopbits=serial.STOPBITS_ONE,
                           timeout=min(0.1, args.timeout), write_timeout=args.timeout,
                           xonxoff=False, rtscts=False, dsrdtr=False) as port:
            emit = (lambda line: print(line, flush=True)
                    if not args.quiet or line.startswith(('RESULT ', 'ERR '))
                    else None)
            if args.command == 'run':
                run_slot(port, args.slot, args.timeout, emit=emit)
            elif args.command == 'upload':
                pixels = load_pixels(args.image, args.slot)
                run_image(port, pixels, args.frame_id, args.timeout, emit=emit)
            else:
                reader = Lines(port)
                while True:
                    try:
                        line = reader.read(time.monotonic() + args.timeout)
                    except TimeoutError:
                        continue
                    if line.startswith('RESULT '):
                        parse_result(line)
                    if line:
                        print(line, flush=True)
    except KeyboardInterrupt:
        return 0
    except (OSError, serial.SerialException, TimeoutError, RuntimeError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
