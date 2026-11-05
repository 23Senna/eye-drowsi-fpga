import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from unittest.mock import Mock
import threading
import io
from contextlib import redirect_stdout


@unittest.skipUnless(importlib.util.find_spec('cv2') and importlib.util.find_spec('mediapipe'),
                     'Camera dependencies available in .venv-camera')
class PreviewTests(unittest.TestCase):
    def test_default_reyn_pixels_reach_uart_mailbox_unchanged(self):
        import cv2
        import mediapipe as mp
        import numpy as np
        from live_webcam import main
        from live_transport import Mailbox
        from eye_capture import LEFT_EYE, LEFT_BROW, get_points, crop_eye_brow
        points=[SimpleNamespace(x=0.5,y=0.5) for _ in range(478)]
        for idx,(x,y) in zip(LEFT_EYE,[(.4,.5),(.45,.48),(.55,.48),(.6,.5),(.55,.52),(.45,.52)]):
            points[idx]=SimpleNamespace(x=x,y=y)
        for idx in LEFT_BROW:
            points[idx]=SimpleNamespace(x=.5,y=.4)
        gray=((np.indices((480,640)).sum(axis=0))%256).astype(np.uint8)
        expected,_=crop_eye_brow(gray,get_points(points,LEFT_EYE,640,480),
                                  get_points(points,LEFT_BROW,640,480),640,480,offset_y=.10)
        camera=Mock()
        camera.isOpened.return_value=True
        camera.read.side_effect=lambda:(True,cv2.cvtColor(gray,cv2.COLOR_GRAY2BGR))
        mesh=Mock()
        mesh.process.return_value=SimpleNamespace(multi_face_landmarks=[SimpleNamespace(landmark=points)])
        worker=Mock()
        worker.error=None
        worker.ready=threading.Event();worker.ready.set()
        worker.busy=threading.Event()
        worker.mailbox=Mailbox()
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(cv2,'VideoCapture',return_value=camera), \
             patch.object(mp.solutions.face_mesh,'FaceMesh',return_value=mesh), \
             patch.object(cv2,'namedWindow'), patch.object(cv2,'imshow'), \
             patch.object(cv2,'waitKey',side_effect=[ord(' '),ord('q')]), \
             patch.object(cv2,'getWindowProperty',return_value=1), \
             patch.object(cv2,'destroyAllWindows'), \
             patch('live_webcam.Transport',return_value=worker):
            self.assertEqual(main(['--port','FAKE','--log-dir',directory]),0)
            pixels,_,_,label=worker.mailbox.item
            # Default --norm train: the reyn crop shifted to the training mean/std is what gets uploaded.
            from check_crops import match_train
            self.assertEqual(pixels,match_train(expected).tobytes())
            self.assertEqual(len(pixels),576)
            self.assertIsNone(label)
            events=[json.loads(line) for line in next(Path(directory).rglob('events.jsonl')).read_text().splitlines()]
            self.assertEqual(events[0]['roi_style'],'reyn')
            self.assertEqual(events[0]['pad'],.15)
            self.assertEqual(events[0]['crop_offset_y'],.10)
            self.assertEqual(events[0]['contrast_levels'],[60,235])
        worker.close.assert_called_once()

    def test_gui_stop_emits_json_and_closes_without_capturing(self):
        import cv2
        import mediapipe as mp
        from live_webcam import main
        camera=Mock()
        camera.isOpened.return_value=True
        mesh=Mock()
        output=io.StringIO()
        class ImmediateReader:
            def __init__(self,target,**kwargs):self.target=target
            def start(self):self.target()
        with tempfile.TemporaryDirectory() as directory, redirect_stdout(output), \
             patch('sys.stdin',io.StringIO('STOP\n')), \
             patch('live_webcam.threading.Thread',ImmediateReader), \
             patch.object(cv2,'VideoCapture',return_value=camera), \
             patch.object(mp.solutions.face_mesh,'FaceMesh',return_value=mesh), \
             patch.object(cv2,'namedWindow'), patch.object(cv2,'destroyAllWindows'):
            self.assertEqual(main(['--preview-only','--gui-control','--log-dir',directory]),0)
            camera.read.assert_not_called()
            camera.release.assert_called_once()
            mesh.close.assert_called_once()
        events=[json.loads(line[11:]) for line in output.getvalue().splitlines() if line.startswith('LIVE_EVENT ')]
        self.assertEqual(events[0]['event'],'session')
        self.assertEqual(events[-1]['event'],'session_end')
        self.assertEqual(events[-1]['exit_code'],0)

    def test_headless_preview_crops_and_never_opens_uart(self):
        import cv2
        import mediapipe as mp
        import numpy as np
        from live_webcam import main
        points=[SimpleNamespace(x=0.5,y=0.5) for _ in range(478)]
        points[362]=SimpleNamespace(x=0.4,y=0.5)
        points[263]=SimpleNamespace(x=0.6,y=0.5)
        points[386]=SimpleNamespace(x=0.5,y=0.48)
        points[374]=SimpleNamespace(x=0.5,y=0.52)
        class Camera:
            released=False
            def isOpened(self):return True
            def set(self,prop,value):return True
            def read(self):return True,np.full((480,640,3),100,dtype=np.uint8)
            def release(self):self.released=True
        class Mesh:
            closed=False
            def process(self,frame):return SimpleNamespace(multi_face_landmarks=[SimpleNamespace(landmark=points)])
            def close(self):self.closed=True
        camera,mesh=Camera(),Mesh()
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(cv2,'VideoCapture',return_value=camera), \
             patch.object(mp.solutions.face_mesh,'FaceMesh',return_value=mesh), \
             patch.object(cv2,'namedWindow'), patch.object(cv2,'imshow') as show, \
             patch.object(cv2,'waitKey',return_value=ord('q')), \
             patch.object(cv2,'destroyAllWindows'), patch('serial.Serial') as serial:
            self.assertEqual(main(['--preview-only','--log-dir',directory]),0)
            serial.assert_not_called()
            self.assertEqual(show.call_args_list[0].args[1].shape,(192,192))
            events=[json.loads(line) for line in next(Path(directory).rglob('events.jsonl')).read_text().splitlines()]
            self.assertTrue(any(e['event']=='face_available' and e['value'] for e in events))
            self.assertEqual(events[-1]['exit_code'],0)
        self.assertTrue(camera.released and mesh.closed)


if __name__=='__main__':unittest.main()
