import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace
import unittest


@unittest.skipUnless(importlib.util.find_spec('cv2') and importlib.util.find_spec('mediapipe'),
                     'Camera environment required')
class RoiTests(unittest.TestCase):
    def test_reyn_brow_crop_and_contrast(self):
        import numpy as np
        from eye_capture import crop_eye_brow, reduce_contrast
        eye = np.array([[100, 140], [110, 135], [130, 135],
                        [140, 140], [130, 145], [110, 145]])
        brow = np.array([[95, 115], [110, 108], [140, 115]])
        gray = np.zeros((240, 320), dtype=np.uint8)
        crop, box = crop_eye_brow(gray, eye, brow, 320, 240)
        self.assertEqual(crop.shape, (24, 24))
        self.assertEqual(crop.dtype, np.uint8)
        self.assertTrue((crop == 60).all())
        self.assertLess(box[1], brow[:, 1].min())
        self.assertGreater(box[3], eye[:, 1].max())
        _, lowered = crop_eye_brow(gray, eye, brow, 320, 240, offset_y=.10)
        self.assertEqual((lowered[0],lowered[2]), (box[0],box[2]))
        self.assertGreater(lowered[1],box[1])
        self.assertGreater(lowered[3],box[3])
        self.assertLessEqual(abs((lowered[3]-lowered[1])-(box[3]-box[1])),1)
        self.assertEqual(reduce_contrast(np.array([0, 255], dtype=np.uint8)).tolist(), [60, 235])
        rejected, _ = crop_eye_brow(gray, eye - 130, brow - 130, 320, 240)
        self.assertIsNone(rejected)

    def test_ear_distinguishes_open_and_closed_geometry(self):
        import numpy as np
        from eye_capture import eye_aspect_ratio, EAR_THRESH
        opened = np.array([[0, 0], [3, -2], [7, -2], [10, 0], [7, 2], [3, 2]])
        closed = opened.copy()
        closed[:, 1] = 0
        self.assertGreater(eye_aspect_ratio(opened), EAR_THRESH)
        self.assertLess(eye_aspect_ratio(closed), EAR_THRESH)

    def test_phone_anchor_does_not_follow_lid_opening(self):
        import numpy as np
        sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
        from eye_capture import crop_eye,LEFT_EYE
        points=[SimpleNamespace(x=.5,y=.5) for _ in range(478)]
        points[362]=SimpleNamespace(x=.4,y=.5);points[263]=SimpleNamespace(x=.6,y=.5)
        gray=np.full((480,640),100,dtype=np.uint8)
        opened,box=crop_eye(gray,points,LEFT_EYE,640,480,pad=.9,style='phone')
        points[386]=SimpleNamespace(x=.51,y=.40);points[374]=SimpleNamespace(x=.49,y=.52)
        closed,closed_box=crop_eye(gray,points,LEFT_EYE,640,480,pad=.9,style='phone')
        self.assertEqual(box,closed_box)
        self.assertEqual(opened.shape,(24,24));self.assertEqual(opened.dtype,np.uint8)
        self.assertEqual(len(closed.tobytes()),576)
        self.assertGreater(box[2]-box[0],230)
        self.assertLess((box[1]+box[3])/2,240)

    def test_legacy_default_unchanged_and_edge_rejected(self):
        import numpy as np
        from eye_capture import crop_eye,LEFT_EYE
        points=[SimpleNamespace(x=.5,y=.5) for _ in range(478)]
        points[362]=SimpleNamespace(x=.4,y=.5);points[263]=SimpleNamespace(x=.6,y=.5)
        gray=np.full((480,640),100,dtype=np.uint8)
        _,box=crop_eye(gray,points,LEFT_EYE,640,480)
        self.assertEqual(box,(233,153,406,326))
        points[362]=SimpleNamespace(x=.01,y=.1);points[263]=SimpleNamespace(x=.21,y=.1)
        crop,_=crop_eye(gray,points,LEFT_EYE,640,480,pad=.9,style='phone')
        self.assertIsNone(crop)
        with self.assertRaises(ValueError):crop_eye(gray,points,LEFT_EYE,640,480,style='bad')
