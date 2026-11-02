"""Control and monitor the Basys3 CNN over a line-oriented 115200 8N1 UART."""
import argparse
import re
import sys
import time

RESULT = re.compile(
    r"RESULT source=(BOARD|PC|SEQ) slot=(\d+) class=(OPEN|CLOSED) "
    r"warning=(AWAKE|DROWSY|MICROSLEEP) logit0=(-?\d+) logit1=(-?\d+) cycles=(\d+) us=(\d+)$")


def parse_result(line):
    match = RESULT.fullmatch(line)
    if not match:
        raise ValueError("Malformed RESULT: " + line)
    source, slot, eye_class, warning, l0, l1, cycles, us = match.groups()
    values = dict(source=source, slot=int(slot), eye_class=eye_class, warning=warning,
                  logit0=int(l0), logit1=int(l1), cycles=int(cycles), us=int(us))
    if not 0 <= values['slot'] <= 15:
        raise ValueError('Result slot outside 0..15')
    if not all(-(1 << 31) <= values[k] < (1 << 31) for k in ('logit0', 'logit1')):
        raise ValueError('Result logits outside int32')
    if not all(0 <= values[k] < (1 << 32) for k in ('cycles', 'us')):
        raise ValueError('Result timing outside uint32')
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


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', help='Serial port, e.g. COM4')
    parser.add_argument('--baud', type=int, default=115200)
    parser.add_argument('--timeout', type=float, default=2.0)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('ports', help='List available serial ports')
    run = sub.add_parser('run', help='Select a slot, run once and print its result')
    run.add_argument('--slot', type=int, required=True, choices=range(16), metavar='0..15')
    sub.add_parser('monitor', help='Print results/replies from all board modes until Ctrl+C')
    args = parser.parse_args(argv)
    if args.timeout <= 0 or args.baud <= 0:
        parser.error('baud and timeout must be positive')
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
            if args.command == 'run':
                run_slot(port, args.slot, args.timeout)
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
