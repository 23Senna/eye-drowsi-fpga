import os
import argparse
import time
import cv2
import numpy as np
import mediapipe as mp

# ---------------- Settings ----------------
OUT_DIR    = "eye_dataset"
CAM_INDEX  = 0
FPS_SAVE   = 10          # images saved per second
EYE_SIZE   = 24          # output = 24x24 grayscale
PAD        = 0.35        # extra margin around the eye (fraction of eye width)
# ------------------------------------------

# MediaPipe landmark indices: (outer corner, inner corner, top lid, bottom lid)
# "right"/"left" refer to the person's own eyes
RIGHT_EYE = (33, 133, 159, 145)
LEFT_EYE  = (362, 263, 386, 374)

def crop_eye(gray, landmarks, idx, w, h):
    """Crop a square region around one eye and resize to EYE_SIZE x EYE_SIZE."""
    pts = np.array([(landmarks[i].x * w, landmarks[i].y * h) for i in idx])
    cx, cy = pts.mean(axis=0)
    eye_w = np.linalg.norm(pts[0] - pts[1])
    half = eye_w * (1 + PAD) / 2           # square crop, half side length

    x1, x2 = int(cx - half), int(cx + half)
    y1, y2 = int(cy - half), int(cy + half)
    if x1 < 0 or y1 < 0 or x2 > w or y2 > h:
        return None, (x1, y1, x2, y2)

    crop = gray[y1:y2, x1:x2]
    if crop.size == 0:
        return None, (x1, y1, x2, y2)
    crop = cv2.resize(crop, (EYE_SIZE, EYE_SIZE), interpolation=cv2.INTER_AREA)
    return crop, (x1, y1, x2, y2)


def main():
    parser = argparse.ArgumentParser(description="Capture 24x24 eye crops from a camera.")
    parser.add_argument("--out-dir", default=OUT_DIR, help="Output directory for left/right crops")
    parser.add_argument("--record", action="store_true", help="Start saving frames immediately")
    args = parser.parse_args()
    out_dir = args.out_dir
    os.makedirs(os.path.join(out_dir, "left"), exist_ok=True)
    os.makedirs(os.path.join(out_dir, "right"), exist_ok=True)

    cap = cv2.VideoCapture(CAM_INDEX)
    if not cap.isOpened():
        raise RuntimeError("Cannot open camera")

    face_mesh = mp.solutions.face_mesh.FaceMesh(
        max_num_faces=1,
        refine_landmarks=True,
        min_detection_confidence=0.5,
        min_tracking_confidence=0.5,
    )

    interval = 1.0 / FPS_SAVE
    last_save = 0.0
    frame_id = 0
    recording = args.record

    print("Press SPACE to start/stop saving, Q to quit.", flush=True)

    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                break

            h, w = frame.shape[:2]
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            result = face_mesh.process(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))

            if result.multi_face_landmarks:
                lm = result.multi_face_landmarks[0].landmark
                left_img,  lbox = crop_eye(gray, lm, LEFT_EYE,  w, h)
                right_img, rbox = crop_eye(gray, lm, RIGHT_EYE, w, h)

                # draw boxes for preview
                for box in (lbox, rbox):
                    cv2.rectangle(frame, box[:2], box[2:], (0, 255, 0), 1)

                now = time.time()
                if (recording and left_img is not None and right_img is not None
                        and now - last_save >= interval):
                    cv2.imwrite(f"{out_dir}/left/{frame_id:06d}.png",  left_img)
                    cv2.imwrite(f"{out_dir}/right/{frame_id:06d}.png", right_img)
                    frame_id += 1
                    last_save = now

                # show the 24x24 crops enlarged in the corner
                if left_img is not None and right_img is not None:
                    preview = np.hstack([left_img, right_img])
                    preview = cv2.resize(preview, None, fx=4, fy=4,
                                         interpolation=cv2.INTER_NEAREST)
                    ph, pw = preview.shape
                    frame[0:ph, 0:pw] = cv2.cvtColor(preview, cv2.COLOR_GRAY2BGR)

            status = f"REC  saved: {frame_id}" if recording else "PAUSED (SPACE to record)"
            cv2.putText(frame, status, (10, h - 15), cv2.FONT_HERSHEY_SIMPLEX,
                        0.6, (0, 0, 255) if recording else (255, 255, 255), 2)
            cv2.imshow("Eye capture", frame)

            key = cv2.waitKey(1) & 0xFF
            if key == ord('q') or cv2.getWindowProperty("Eye capture", cv2.WND_PROP_VISIBLE) < 1:
                break
            elif key == ord(' '):
                recording = not recording
    finally:
        cap.release()
        face_mesh.close()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()