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
EYE_SIZE   = 24          # fixed 24x24 grayscale for the FPGA model
PAD        = 0.15        # extra margin around the eye + eyebrow box

BLACK_LEVEL = 60         # darkest value in saved images (0 = pure black, higher = washed-out blacks)
WHITE_LEVEL = 235        # brightest value in saved images (255 = pure white)

EAR_THRESH = 0.21        # below this = eye closed (adjust live with + / -)
DROWSY_SEC = 0.7         # both eyes closed longer than this = DROWSY (longer than a blink)
SLEEP_SEC  = 1.5         # both eyes closed longer than this = SLEEPING
# ------------------------------------------

# 6 landmarks per eye for EAR: (outer corner, top1, top2, inner corner, bottom2, bottom1)
# "right"/"left" refer to the person's own eyes
RIGHT_EYE  = (33, 160, 158, 133, 153, 144)
LEFT_EYE   = (362, 385, 387, 263, 373, 380)

# eyebrow landmarks (included in the crop so the eyebrow is visible)
RIGHT_BROW = (70, 63, 105, 66, 107)
LEFT_BROW  = (336, 296, 334, 293, 300)

GREEN  = (0, 200, 0)
RED    = (0, 0, 255)
ORANGE = (0, 165, 255)
WHITE  = (255, 255, 255)
GRAY   = (60, 60, 60)

# Compatibility geometry used by the UART live client.
LEGACY_RIGHT_EYE = (33, 133, 159, 145)
LEGACY_LEFT_EYE = (362, 263, 386, 374)


def crop_eye(gray, landmarks, idx, w, h, pad=None, style='legacy', offset_y=0.0):
    """Crop a square region around one eye and resize to EYE_SIZE x EYE_SIZE."""
    if pad is None:
        pad = PAD if style == 'reyn' else 0.35
    # Keep existing live phone/legacy geometry when callers use EAR landmarks.
    is_left = tuple(idx) in (LEFT_EYE, LEGACY_LEFT_EYE)
    if style == 'reyn':
        eye_idx = LEFT_EYE if is_left else RIGHT_EYE
        brow_idx = LEFT_BROW if is_left else RIGHT_BROW
        return crop_eye_brow(gray, get_points(landmarks, eye_idx, w, h),
                             get_points(landmarks, brow_idx, w, h), w, h, pad=pad, offset_y=offset_y)
    if tuple(idx) == LEFT_EYE:
        idx = LEGACY_LEFT_EYE
    elif tuple(idx) == RIGHT_EYE:
        idx = LEGACY_RIGHT_EYE
    pts = np.array([(landmarks[i].x * w, landmarks[i].y * h) for i in idx])
    eye_w = np.linalg.norm(pts[0] - pts[1])
    if style not in ('legacy','phone'):
        raise ValueError('Unknown eye ROI style')
    if not np.isfinite(pts).all() or eye_w < 1:
        return None, (0,0,0,0)
    if style == 'phone':
        # Measured manual-phone geometry: ~1.9 eye widths, center above
        # the eyelid line. Corners keep the anchor independent of lid opening.
        cx, cy = pts[:2].mean(axis=0)
        cx += (0.10 if is_left else -0.10) * eye_w
        cy -= 0.16 * eye_w
    else:
        cx, cy = pts.mean(axis=0)
    half = eye_w * (1 + pad) / 2           # square crop, half side length
    cy += offset_y * (2 * half)           # positive = down, fraction of crop side

    x1, x2 = int(cx - half), int(cx + half)
    y1, y2 = int(cy - half), int(cy + half)
    if x1 < 0 or y1 < 0 or x2 > w or y2 > h:
        return None, (x1, y1, x2, y2)

    crop = gray[y1:y2, x1:x2]
    if crop.size == 0:
        return None, (x1, y1, x2, y2)
    crop = cv2.resize(crop, (EYE_SIZE, EYE_SIZE), interpolation=cv2.INTER_AREA)
    return crop, (x1, y1, x2, y2)



def get_points(landmarks, idx, w, h):
    return np.array([(landmarks[i].x * w, landmarks[i].y * h) for i in idx])


def eye_aspect_ratio(p):
    """EAR = (|p2-p6| + |p3-p5|) / (2 * |p1-p4|)"""
    v1 = np.linalg.norm(p[1] - p[5])
    v2 = np.linalg.norm(p[2] - p[4])
    hz = np.linalg.norm(p[0] - p[3])
    return (v1 + v2) / (2.0 * hz + 1e-6)


def crop_eye_brow(gray, eye_pts, brow_pts, w, h, pad=PAD, offset_y=0.0):
    """Square crop covering the eye AND eyebrow, resized to EYE_SIZE x EYE_SIZE."""
    pts = np.vstack([eye_pts, brow_pts])
    if not np.isfinite(pts).all():
        return None, (0, 0, 0, 0)
    x_min, y_min = pts.min(axis=0)
    x_max, y_max = pts.max(axis=0)
    cx, cy = (x_min + x_max) / 2, (y_min + y_max) / 2
    half = max(x_max - x_min, y_max - y_min) * (1 + pad) / 2   # square
    cy += offset_y * (2 * half)           # positive = down, fraction of crop side

    x1, x2 = int(cx - half), int(cx + half)
    y1, y2 = int(cy - half), int(cy + half)
    if x1 < 0 or y1 < 0 or x2 > w or y2 > h:
        return None, (x1, y1, x2, y2)

    crop = gray[y1:y2, x1:x2]
    if crop.size == 0:
        return None, (x1, y1, x2, y2)
    crop = cv2.resize(crop, (EYE_SIZE, EYE_SIZE), interpolation=cv2.INTER_AREA)
    crop = reduce_contrast(crop)
    return crop, (x1, y1, x2, y2)


def reduce_contrast(img):
    """Compress 0..255 into BLACK_LEVEL..WHITE_LEVEL so blacks are lifted."""
    out = BLACK_LEVEL + img.astype(np.float32) * (WHITE_LEVEL - BLACK_LEVEL) / 255.0
    return np.clip(out, 0, 255).astype(np.uint8)


def draw_panel(frame, l_ear, r_ear, l_closed, r_closed, status, closed_time, thresh):
    """Status panel on the right side of the frame."""
    h, w = frame.shape[:2]
    pw, ph = 230, 215
    x0, y0 = w - pw - 10, 10

    overlay = frame.copy()
    cv2.rectangle(overlay, (x0, y0), (x0 + pw, y0 + ph), GRAY, -1)
    cv2.addWeighted(overlay, 0.75, frame, 0.25, 0, frame)

    def badge(y, label, ear, closed):
        col = RED if closed else GREEN
        txt = "CLOSED" if closed else "OPEN"
        cv2.putText(frame, label, (x0 + 10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.55, WHITE, 1)
        cv2.circle(frame, (x0 + 95, y - 5), 8, col, -1)
        cv2.putText(frame, txt, (x0 + 110, y), cv2.FONT_HERSHEY_SIMPLEX, 0.6, col, 2)
        cv2.putText(frame, f"EAR {ear:.2f}", (x0 + 10, y + 20),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, (200, 200, 200), 1)

    if l_ear is None:
        cv2.putText(frame, "No face", (x0 + 10, y0 + 40),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, ORANGE, 2)
    else:
        badge(y0 + 30, "Left", l_ear, l_closed)
        badge(y0 + 80, "Right", r_ear, r_closed)

    # status banner
    col = {"AWAKE": GREEN, "DROWSY": ORANGE, "SLEEPING": RED}.get(status, ORANGE)
    cv2.rectangle(frame, (x0 + 10, y0 + 120), (x0 + pw - 10, y0 + 160), col, -1)
    cv2.putText(frame, status, (x0 + 22, y0 + 149),
                cv2.FONT_HERSHEY_SIMPLEX, 0.9, WHITE, 2)

    cv2.putText(frame, f"Eyes closed: {closed_time:.1f}s", (x0 + 10, y0 + 182),
                cv2.FONT_HERSHEY_SIMPLEX, 0.5, WHITE, 1)
    cv2.putText(frame, f"Threshold: {thresh:.2f}  (+/-)", (x0 + 10, y0 + 202),
                cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1)

    # red border when sleeping
    if status == "SLEEPING":
        cv2.rectangle(frame, (0, 0), (w - 1, h - 1), RED, 6)


def main():
    parser = argparse.ArgumentParser(description="Record eye/eyebrow crops; EAR indicators are computed on the laptop.")
    parser.add_argument('--out-dir', default=OUT_DIR)
    parser.add_argument('--camera', type=int, default=CAM_INDEX)
    args = parser.parse_args()
    out_dir = args.out_dir
    os.makedirs(os.path.join(out_dir, "left"), exist_ok=True)
    os.makedirs(os.path.join(out_dir, "right"), exist_ok=True)
    thresh = EAR_THRESH
    cap = cv2.VideoCapture(args.camera)
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
    recording = False
    closed_since = None      # time when both eyes became closed

    print("SPACE = start/stop saving | + / - = EAR threshold | Q = quit")

    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                break

            h, w = frame.shape[:2]
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            result = face_mesh.process(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
            now = time.monotonic()

            l_ear = r_ear = None
            l_closed = r_closed = False
            status = "NO FACE"
            closed_time = 0.0

            if result.multi_face_landmarks:
                lm = result.multi_face_landmarks[0].landmark

                l_eye = get_points(lm, LEFT_EYE, w, h)
                r_eye = get_points(lm, RIGHT_EYE, w, h)
                l_brow = get_points(lm, LEFT_BROW, w, h)
                r_brow = get_points(lm, RIGHT_BROW, w, h)

                # open / closed from the eye aspect ratio
                l_ear = eye_aspect_ratio(l_eye)
                r_ear = eye_aspect_ratio(r_eye)
                l_closed = l_ear < thresh
                r_closed = r_ear < thresh

                # awake / drowsy / sleeping from how long BOTH eyes stay closed
                if l_closed and r_closed:
                    if closed_since is None:
                        closed_since = now
                    closed_time = now - closed_since
                else:
                    closed_since = None

                if closed_time >= SLEEP_SEC:
                    status = "SLEEPING"
                elif closed_time >= DROWSY_SEC:
                    status = "DROWSY"
                else:
                    status = "AWAKE"

                # crops that include the eyebrow
                left_img,  lbox = crop_eye_brow(gray, l_eye, l_brow, w, h)
                right_img, rbox = crop_eye_brow(gray, r_eye, r_brow, w, h)

                # boxes: green = open, red = closed
                cv2.rectangle(frame, lbox[:2], lbox[2:], RED if l_closed else GREEN, 1)
                cv2.rectangle(frame, rbox[:2], rbox[2:], RED if r_closed else GREEN, 1)

                # save at 10 fps; the eye state is added to the filename as a label
                if (recording and left_img is not None and right_img is not None
                        and now - last_save >= interval):
                    ls = "closed" if l_closed else "open"
                    rs = "closed" if r_closed else "open"
                    cv2.imwrite(f"{out_dir}/left/{frame_id:06d}_{ls}.png",  left_img)
                    cv2.imwrite(f"{out_dir}/right/{frame_id:06d}_{rs}.png", right_img)
                    frame_id += 1
                    last_save = now

                # show the saved crops enlarged in the top-left corner
                if left_img is not None and right_img is not None:
                    preview = np.hstack([left_img, right_img])
                    preview = cv2.resize(preview, None, fx=4, fy=4,
                                         interpolation=cv2.INTER_NEAREST)
                    ph, pw = preview.shape
                    frame[0:ph, 0:pw] = cv2.cvtColor(preview, cv2.COLOR_GRAY2BGR)
            else:
                closed_since = None

            draw_panel(frame, l_ear, r_ear, l_closed, r_closed,
                       status, closed_time, thresh)

            rec_txt = f"REC  saved: {frame_id}" if recording else "PAUSED (SPACE to record)"
            cv2.putText(frame, rec_txt, (10, h - 15), cv2.FONT_HERSHEY_SIMPLEX,
                        0.6, RED if recording else WHITE, 2)
            cv2.imshow("Eye capture", frame)

            key = cv2.waitKey(1) & 0xFF
            if key == ord('q') or cv2.getWindowProperty('Eye capture', cv2.WND_PROP_VISIBLE) < 1:
                break
            elif key == ord(' '):
                recording = not recording
            elif key in (ord('+'), ord('=')):
                thresh = min(0.40, thresh + 0.01)
            elif key in (ord('-'), ord('_')):
                thresh = max(0.05, thresh - 0.01)
    finally:
        face_mesh.close()
        cap.release()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
