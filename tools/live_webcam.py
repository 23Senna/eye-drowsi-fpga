"""Live one-eye capture, CRC UART inference and responsive preview."""
import argparse
import datetime
import json
from pathlib import Path
import queue
from collections import deque
import sys
import time
import threading
from live_transport import Transport, clock

ROOT = Path(__file__).resolve().parents[1]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', help='FPGA COM port; required unless --preview-only or --dry-run')
    parser.add_argument('--baud',type=int,default=None,help='UART baud; must match the bitstream (default uart_cli.DEFAULT_BAUD = 1000000)')
    parser.add_argument('--dry-run',action='store_true',help='No board: tools/fake_fpga.py (integer CNN + DrowsyRef, modelled wire/USB time)')
    parser.add_argument('--usb-ms',type=float,default=1.0,help='--dry-run only: modelled FTDI latency timer per reply (Windows default 16)')
    parser.add_argument('--camera',type=int,default=0)
    parser.add_argument('--backend',choices=['auto','dshow','msmf'],default='dshow')
    parser.add_argument('--eye',choices=['left','right'],default='left',help="Person's own eye, before any mirroring")
    parser.add_argument('--fps',type=float,default=10,help='Target inference rate, not preview FPS')
    parser.add_argument('--frame-id',type=int,default=1000)
    parser.add_argument('--max-gap',type=float,default=0.5,help='Pause after this many seconds without a valid crop/result')
    parser.add_argument('--preview-only',action='store_true',help='Capture/landmarks without opening serial')
    parser.add_argument('--diagnostics',action='store_true',help='Save exact uploaded eye crops and compare integer golden logits; O/C/U label subsequent captures')
    parser.add_argument('--roi-style',choices=['legacy','phone','reyn'],default='reyn',help='Default reyn: eye+brow crop and contrast 60..235; phone/legacy: earlier crops without contrast remapping')
    parser.add_argument('--pad',type=float,default=None,help='Extra square margin: defaults to 0.15 reyn, 0.35 legacy, 0.90 phone')
    parser.add_argument('--crop-offset-y',type=float,default=None,help='Vertical shift as fraction of crop side; positive down. Default 0.10 reyn, 0 other styles')
    parser.add_argument('--check',action='store_true',help='Check imports and versions without opening camera/serial')
    parser.add_argument('--gui-control',action='store_true',help='GUI bridge: START/STOP on stdin; LIVE_EVENT JSON on stdout')
    parser.add_argument('--log-dir',type=Path,default=ROOT/'build/live_sessions')
    args=parser.parse_args(argv)
    if args.pad is None:args.pad={'reyn':0.15,'phone':0.90,'legacy':0.35}[args.roi_style]
    if args.crop_offset_y is None:args.crop_offset_y=0.10 if args.roi_style=='reyn' else 0.0
    if not 0 < args.fps <= 10 or not 0 <= args.frame_id <= 65535 or args.max_gap < 0.3:
        parser.error('fps must be >0..10, frame-id 0..65535, max-gap >=0.3')
    if not 0<=args.pad<=2:parser.error('pad must be 0..2')
    if not -0.5<=args.crop_offset_y<=0.5:parser.error('crop-offset-y must be -0.5..0.5')
    if not args.port and not args.preview_only and not args.check and not args.dry_run:
        parser.error('--port is required unless --preview-only, --dry-run or --check')
    from uart_cli import DEFAULT_BAUD
    args.baud=args.baud or DEFAULT_BAUD
    try:
        import cv2
        import mediapipe as mp
        import serial
        if not hasattr(mp,'solutions'):
            raise RuntimeError('MediaPipe legacy FaceMesh missing; install requirements-live.txt with Python 3.12')
        sys.path.insert(0,str(ROOT))
        from eye_capture import crop_eye, LEFT_EYE, RIGHT_EYE, BLACK_LEVEL, WHITE_LEVEL
        if args.check:
            print(f'Python {sys.version.split()[0]}, OpenCV {cv2.__version__}, MediaPipe {mp.__version__}, pySerial {serial.VERSION}')
            return 0
    except (ImportError,RuntimeError) as exc:
        print(f'Environment error: {exc}. Use .venv-camera and tools/requirements-live.txt',file=sys.stderr)
        return 1
    session=args.log_dir/datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    session.mkdir(parents=True,exist_ok=False)
    crop_description=(f'reyn eye+brow | pad {args.pad:.2f} | contrast {BLACK_LEVEL}..{WHITE_LEVEL}'
                      if args.roi_style=='reyn' else f'{args.roi_style} | {1 + args.pad:.2f}x eye width')
    crop_description+=f' | Y {args.crop_offset_y:+.2f}'
    print(f'Eye crop: {crop_description} | output 24x24 grayscale',flush=True)
    events=queue.SimpleQueue()
    worker=None
    cap=None
    mesh=None
    log=None
    status='PREVIEW ONLY' if args.preview_only else 'Reset btnU, SW9 UP, SW13 DOWN; SPACE to start'
    running=False
    last_crop=last_result=clock()
    last_face_notice=None
    result=None
    last_result_capture=0
    roundtrip_ms=observed_hz=None
    send_times=deque(maxlen=11)
    stage={k:deque(maxlen=300) for k in ('capture','crop','mailbox_wait_ms','uart_ready','uart_frame','uart_run',
        'uart_result','roundtrip_ms','capture_to_result_ms')}
    all_sends=[]
    label=None
    golden_status=''
    sequence=0
    exit_code=0
    commands=queue.SimpleQueue()
    pending_start=False
    previous_state=None
    if args.gui_control:
        def read_commands():
            for line in sys.stdin:
                commands.put(line.strip().upper())
            commands.put('STOP')
        threading.Thread(target=read_commands,daemon=True).start()
    def record(event):
        event={'wall_time':datetime.datetime.now().astimezone().isoformat(),**event}
        log.write(json.dumps(event)+'\n')
        log.flush()
        if args.gui_control:
            print('LIVE_EVENT '+json.dumps(event),flush=True)
    try:
        log=(session/'events.jsonl').open('w',encoding='utf-8')
        record({'event':'session','camera':args.camera,'backend':args.backend,'eye':args.eye,
                'target_fps':args.fps,'port':args.port,'baud':args.baud,'dry_run':args.dry_run,'preview_only':args.preview_only,
                'diagnostics':args.diagnostics,'pad':args.pad,'roi_style':args.roi_style,
                'crop_offset_y':args.crop_offset_y,
                'contrast_levels':[BLACK_LEVEL,WHITE_LEVEL] if args.roi_style=='reyn' else None,
                'preprocessing':'MediaPipe landmarks + OpenCV grayscale/INTER_AREA 24x24',
                'note':'Diagnostics saves uploaded eye crops only; board history is observation-count based'})
        api={'auto':cv2.CAP_ANY,'dshow':cv2.CAP_DSHOW,'msmf':cv2.CAP_MSMF}[args.backend]
        cap=cv2.VideoCapture(args.camera,api)
        if not cap.isOpened():
            raise RuntimeError('Cannot open webcam; try --camera 1 or --backend msmf')
        cap.set(cv2.CAP_PROP_BUFFERSIZE,1)  # do not queue stale frames in the driver (adds capture latency)
        mesh=mp.solutions.face_mesh.FaceMesh(max_num_faces=1,refine_landmarks=True,
            min_detection_confidence=0.5,min_tracking_confidence=0.5)
        if not args.preview_only:
            audit=None
            if args.diagnostics:
                from live_audit import Audit
                audit=Audit(session/'inputs')
            if args.dry_run:
                from fake_fpga import FakeFpga
                factory=lambda:FakeFpga(args.baud,args.usb_ms)
            else:
                factory=lambda:serial.Serial(args.port,args.baud,timeout=0.05,write_timeout=2,
                    xonxoff=False,rtscts=False,dsrdtr=False)
            worker=Transport(factory,events.put,args.fps,args.frame_id,audit=audit)
            worker.thread.start()
        window='Live eye -> Basys 3 | SPACE start/pause | Q quit'
        cv2.namedWindow(window,cv2.WINDOW_NORMAL)
        while True:
            stop_requested=False
            while not commands.empty():
                command=commands.get()
                if command=='STOP':stop_requested=True
                elif command=='START' and not running:pending_start=True
            if stop_requested:break
            read_start=clock()
            ok,frame=cap.read()
            captured=clock()
            stage['capture'].append((captured-read_start)*1000)
            if not ok:
                raise RuntimeError('Webcam disconnected or frame capture failed')
            sequence+=1
            h,w=frame.shape[:2]
            face=mesh.process(cv2.cvtColor(frame,cv2.COLOR_BGR2RGB))
            crop=None
            if face.multi_face_landmarks:
                crop,box=crop_eye(cv2.cvtColor(frame,cv2.COLOR_BGR2GRAY),
                    face.multi_face_landmarks[0].landmark,LEFT_EYE if args.eye=='left' else RIGHT_EYE,w,h,pad=args.pad,style=args.roi_style,offset_y=args.crop_offset_y)
                if crop is not None:
                    stage['crop'].append((clock()-captured)*1000)
                    last_crop=captured
                    cv2.rectangle(frame,box[:2],box[2:],(0,255,0),2)
                    cv2.imshow('Latest eye crop (not necessarily last inferred frame)',cv2.resize(crop,(192,192),interpolation=cv2.INTER_NEAREST))
            now=clock()
            found=crop is not None
            if not found and worker is not None:
                worker.mailbox.clear()
            if found!=last_face_notice:
                record({'event':'face_available','value':found,'monotonic':now})
                last_face_notice=found
            while not events.empty():
                event=events.get()
                record(event)
                if event['event']=='result':
                    result=event['result'];last_result=event['result_monotonic']
                    last_result_capture=event['captured_monotonic']
                    roundtrip_ms=event['roundtrip_ms']
                    for key in ('roundtrip_ms','capture_to_result_ms','mailbox_wait_ms'):stage[key].append(event[key])
                    for key,value in event['stages_ms'].items():stage['uart_'+key].append(value)
                    send_times.append(event['sent_monotonic']);all_sends.append(event['sent_monotonic'])
                    observed_hz=(len(send_times)-1)/(send_times[-1]-send_times[0]) if len(send_times)>1 and send_times[-1]>send_times[0] else None
                    if 'golden_match' in event:
                        golden_status='Golden '+('MATCH' if event['golden_match'] else 'MISMATCH')
                        pixels=Path(event['input_raw']).read_bytes()
                        import numpy as np
                        exact=np.frombuffer(pixels,dtype=np.uint8).reshape(24,24)
                        cv2.imshow('Last inferred input (matches displayed result)',cv2.resize(exact,(192,192),interpolation=cv2.INTER_NEAREST))
                        print(f"{golden_status} | label={event['operator_label']} | logits={result['logit0']}/{result['logit1']}",flush=True)
                    print(f"{result['frame_id']} {result['eye_class']} {result['warning']} | {event['roundtrip_ms']:.1f} ms | interval {event['capture_interval_ms']}",flush=True)
                elif event['event']=='error':
                    running=False;status='UART ERROR: '+event['message']+' | reset board and restart app';exit_code=1
            if running and (now-last_crop>args.max_gap or now-last_result>args.max_gap):
                running=False;worker.pause()
                status='GAP: wait UART idle, reset btnU, SPACE; FPGA warning may persist'
                record({'event':'gap_pause','monotonic':now})
            if running and found and not worker.error:
                worker.mailbox.put(crop.tobytes(),captured,sequence,label)
            stale=not running or not found or now-last_result_capture>args.max_gap
            state=(running,stale,found,status,worker.busy.is_set() if worker else False)
            if state!=previous_state:
                record({'event':'live_state','running':running,'stale':stale,'face_available':found,
                        'status':status,'busy':state[4]})
                previous_state=state
            detail='NO FRESH RESULT' if result is None or stale else f"#{result['frame_id']} {result['eye_class']} | {result['warning']} | CNN {result['us']} us"
            cv2.putText(frame,detail,(12,30),cv2.FONT_HERSHEY_SIMPLEX,0.65,(0,255,255),2)
            if worker is not None:
                link='UART BUSY - do not reset yet' if worker.busy.is_set() else 'UART IDLE'
                cv2.putText(frame,link,(12,58),cv2.FONT_HERSHEY_SIMPLEX,0.5,(0,255,255),1)
            if roundtrip_ms is not None and not stale:
                rate='-' if observed_hz is None else f'{observed_hz:.1f}'
                cv2.putText(frame,f'Host roundtrip {roundtrip_ms:.1f} ms | observed {rate} Hz',
                            (12,84),cv2.FONT_HERSHEY_SIMPLEX,0.5,(0,255,255),1)
            if args.diagnostics:
                cv2.putText(frame,f'{golden_status} | label: {label or "UNLABELED"} | O=open C=closed U=clear',
                            (12,110),cv2.FONT_HERSHEY_SIMPLEX,0.45,(0,255,255),1)
            cv2.putText(frame,f'Crop: {args.roi_style} | pad {args.pad:.2f} | Y {args.crop_offset_y:+.2f} -> 24x24',
                        (12,h-42),cv2.FONT_HERSHEY_SIMPLEX,0.45,(0,255,255),1)
            cv2.putText(frame,'LIVE' if running else status,(12,h-18),cv2.FONT_HERSHEY_SIMPLEX,0.45,(0,255,255),1)
            cv2.imshow(window,frame)
            key=cv2.waitKey(1)&0xff
            if key!=ord('q') and pending_start and not running and found and worker is not None and worker.ready.is_set() and not worker.busy.is_set():
                key=ord(' ');pending_start=False
            if args.diagnostics and key in (ord('o'),ord('c'),ord('u')):
                label={ord('o'):'OPEN',ord('c'):'CLOSED',ord('u'):None}[key]
                record({'event':'operator_label','label':label,'monotonic':clock()})
            if key==ord('q') or cv2.getWindowProperty(window,cv2.WND_PROP_VISIBLE)<1:
                break
            if key==ord(' ') and worker is not None and not worker.error:
                if running:
                    running=False;worker.pause();status='PAUSED: reset btnU, then SPACE to resume'
                elif found and worker.ready.is_set() and not worker.busy.is_set():
                    running=True;last_crop=last_result=now
                    pending_start=False
                    worker.mailbox.clear();worker.enabled.set();status='LIVE'
                    send_times.clear()
                record({'event':'operator_toggle','running':running,'monotonic':now,
                        'note':'Starting/resuming is operator confirmation of board reset'})
    except (Exception,KeyboardInterrupt) as exc:
        exit_code=1
        print(f'Stopped: {exc}',file=sys.stderr)
        if log is not None:record({'event':'error','message':str(exc)})
    finally:
        if worker is not None:
            try:worker.close()
            except RuntimeError as exc:print(exc,file=sys.stderr);exit_code=1
            while not events.empty():record(events.get())
        if cap is not None:cap.release()
        if mesh is not None:mesh.close()
        cv2.destroyAllWindows()
        if log is not None:
            record({'event':'session_end','exit_code':exit_code,'note':'Stop/pause does not clear FPGA alarm; press btnU'})
            log.close()
        summary=latency_summary(stage,all_sends,args)
        if summary:
            print(summary)
            (session/'latency.txt').write_text(summary+'\n',encoding='utf-8')
        print('Session log:',session)
    return exit_code


def latency_summary(stage,sends,args):
    """Median / p90 per stage in ms (camera read, MediaPipe+crop, UART steps cumulative) and fps."""
    import statistics
    rows=[]
    for key,values in stage.items():
        if values:
            v=sorted(values)
            rows.append(f'  {key:22s} median {statistics.median(v):7.1f}  p90 {v[int(0.9*(len(v)-1))]:7.1f}  n={len(v)}')
    if not rows:return ''
    fps=(len(sends)-1)/(sends[-1]-sends[0]) if len(sends)>1 and sends[-1]>sends[0] else 0
    link='dry-run model usb %.1f ms'%args.usb_ms if args.dry_run else str(args.port)
    return '\n'.join([f'Latency summary ({link}, {args.baud} baud, target {args.fps} fps, measured {fps:.2f} inferences/s):']+rows)


if __name__=='__main__':
    raise SystemExit(main())
