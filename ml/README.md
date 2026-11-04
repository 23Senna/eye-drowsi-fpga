# ml/ — dataset, training, quantisation, export

Run all scripts from inside this folder (they use relative paths). The scripts preserve the team training/export flow.

| Step | Script | In → Out |
|---|---|---|
| 1 | `prepare_data.py` | raw Roboflow YOLO folders `train/ valid/ test/` (`images/`, `labels/`) → `train.npz valid.npz test.npz` (24×24 grayscale eye crops, `X` uint8, `y` 0=closed/1=open) |
| 2 | `train.py` | `*.npz` → `net_float.pt` (prints val accuracy every 10 epochs and float test accuracy) |
| 3 | `quantize_export.py` | `net_float.pt` + `*.npz` → `export/*.mem`, `export/expected.txt`, `export/params.txt`; prints int8 accuracies and required bit widths |
| – | `view_data.py` → `grid.png`; `view_testimg.py` shows the 16 board test images from `export/images.mem` | |

The original training seed and complete dependency versions were not recorded;
retraining is not guaranteed to regenerate byte-identical weights. Committed
export/golden files are the current numerical baseline. Train in an isolated
environment, separate from .venv-camera, and record versions/seed for the next
export.

Requirements: `pip install -r requirements.txt` (numpy, torch, opencv-python, matplotlib). Exact versions the team used were not recorded.

## Data
- Source: Roboflow Universe, workspace `michaelreynaldi890-gmail-com`, project `eye-detection-spucg-tdc0s`, version 1, licence Public Domain — https://universe.roboflow.com/michaelreynaldi890-gmail-com/eye-detection-spucg-tdc0s/dataset/1 (also in `data.yaml`).
- Classes: `eye_closed` (0), `eye_open` (1).
- Crops kept in this repo (`*.npz`, 24×24): train 758 (430 closed / 328 open), valid 216 (116 / 100), test 108 (53 / 55). `grid.png` shows 16 closed (top) and 16 open (bottom) training crops.
- The raw images/labels are **not** in the repo (large, re-downloadable). To rerun step 1, download the dataset in YOLO format and place `train/ valid/ test/` here (they are git-ignored).

## Exported `.mem` format
One value per line, hexadecimal, two's complement; width 8 bit (weights, activations, pixels) or 32 bit (biases). Layouts: see `../docs/ARCHITECTURE.md` §2.
