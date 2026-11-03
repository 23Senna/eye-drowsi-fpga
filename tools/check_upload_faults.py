"""Operator-assisted physical UART checks; never runs automatically on a board."""
import argparse
import binascii
import datetime
import json
from pathlib import Path
import threading
import time

from uart_cli import Lines, load_pixels, run_image, write_all


class Check:
    def __init__(self, port, log):
        self.port = port
        self.reader = Lines(port)
        self.log = log

    def emit(self, text):
        print(text, flush=True)
        self.log.write(text+'\n')
        self.log.flush()

    def expect(self, expected, timeout=3):
        line = self.reader.read(time.monotonic()+timeout)
        self.emit(line)
        if line != expected:
            raise RuntimeError(f'Expected {expected!r}, received {line!r}')

    def command(self, text):
        self.emit('TX '+text)
        write_all(self.port,(text+'\n').encode('ascii'))

    def begin(self, frame_id):
        self.command(f'LOAD {frame_id:04X}')
        self.expect(f'READY {frame_id}')

    def silent(self, seconds=0.2):
        try:
            line=self.reader.read(time.monotonic()+seconds)
        except TimeoutError:
            if self.reader.pending:
                raise RuntimeError('Unexpected incomplete response during silence check')
            return
        self.emit(line)
        raise RuntimeError('Unexpected response/inference after invalid frame')

    def reject_run(self, frame_id):
        self.command(f'RUN_FRAME {frame_id:04X}')
        self.expect('ERR NOFRAME')
        self.silent()


def fault(check, mode, pixels, frame_id, reset_action=None):
    check.begin(frame_id)
    if mode=='crc':
        crc=binascii.crc_hqx(pixels,0xffff)^1
        write_all(check.port,pixels+crc.to_bytes(2,'big'))
        check.emit('TX 576 pixels + deliberately incorrect CRC')
        check.expect('ERR CRC')
    elif mode=='timeout':
        write_all(check.port,pixels[:64])
        check.emit('TX 64/576 pixels; sender stopped without closing the COM port')
        check.expect('ERR TIMEOUT',timeout=4)
    elif mode=='reset':
        if reset_action is None:
            raise ValueError('Reset check requires an operator action')
        reset_action(check)
    else:
        raise ValueError('Unknown fault mode')
    check.reject_run(frame_id)
    check.emit('PASS invalid frame rejected; no RESULT observed in the checked interval')


def operator_reset(check):
    # A keepalive byte every 150 ms prevents the 1-second RX timeout while
    # the operator reaches btnU. Bound count/time so no full frame is sent.
    done=threading.Event()
    errors=[]

    def prompt():
        try:
            input('TEKAN DAN TAHAN btnU, lalu tekan Enter di PC sambil btnU tetap ditahan: ')
        except (EOFError,KeyboardInterrupt) as exc:
            errors.append(exc)
        finally:
            done.set()

    check.emit('RESET TEST: partial upload active; operator must hold btnU during the next prompt')
    write_all(check.port,bytes(64))
    thread=threading.Thread(target=prompt,daemon=True)
    thread.start()
    deadline=time.monotonic()+30
    while not done.wait(0.15):
        if time.monotonic()>=deadline:
            raise TimeoutError('Operator reset not confirmed in 30 seconds; stop, reset board, then retry')
        write_all(check.port,b'\x00')
    thread.join()
    if errors:
        raise RuntimeError('Operator input unavailable; reset test aborted')
    check.port.flush()
    time.sleep(0.05)
    # The operator is still holding reset. No further payload is transmitted.
    check.port.reset_input_buffer()
    check.reader.pending.clear()
    check.emit('TX stopped. btnU must still be held. Now release btnU.')
    input('Lepaskan btnU, tunggu 1 detik (SW9 tetap naik), lalu tekan Enter: ')
    check.emit('Operator confirmed btnU release; checking that partial frame is invalid')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port',required=True)
    parser.add_argument('--test',choices=['crc','timeout','reset'],required=True)
    parser.add_argument('--frame-id',type=int,required=True,help='Decimal 0..65534; recovery uses ID+1')
    args=parser.parse_args(argv)
    if not 0<=args.frame_id<65535:
        parser.error('frame-id must be 0..65534')
    root=Path(__file__).resolve().parents[1]
    # The committed slot-3 pixels have known golden logits. No Pillow needed.
    pixels=load_pixels(root/'ml/export/images.mem',3)
    output=root/'build'/('physical_upload_'+args.test+'_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    output.mkdir(parents=True)
    summary={'test':args.test,'port':args.port,'frame_id':args.frame_id,
             'status':'INCOMPLETE','source':'Host checker with operator-connected hardware',
             'reset_evidence':'Manual operator action' if args.test=='reset' else None,
             'limitation':'Serial observations only; no direct internal cnn_start instrumentation'}
    try:
        import serial
        with (output/'serial.log').open('w',encoding='utf-8') as log:
            with serial.Serial(args.port,115200,timeout=0.05,write_timeout=3,
                               xonxoff=False,rtscts=False,dsrdtr=False) as port:
                check=Check(port,log)
                check.emit(f'TEST {args.test}; SW9 up, SW13 down; frame_id={args.frame_id}')
                check.silent()
                fault(check,args.test,pixels,args.frame_id,operator_reset)
                check.emit('RECOVERY: upload a complete valid image with a fresh ID')
                result=run_image(port,pixels,args.frame_id+1,timeout=3,emit=check.emit)
                if (result['logit0'],result['logit1'],result['cycles'],result['us'])!=(-17106,17976,37290,372) or result['eye_class']!='OPEN':
                    raise RuntimeError('Recovery does not match golden image')
                check.emit(f'PASS {args.test}: rejection and valid-upload recovery match')
                summary.update(status='PASS',recovery=result)
    except (Exception,KeyboardInterrupt) as exc:
        summary.update(status='FAIL',error=str(exc) or type(exc).__name__)
        print('FAIL:',summary['error'],flush=True)
        print('Stop sending. Press/release btnU before retrying with a new ID.',flush=True)
    finally:
        (output/'summary.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
        print('Evidence:',output,flush=True)
    return 0 if summary['status']=='PASS' else 1


if __name__=='__main__':
    raise SystemExit(main())
