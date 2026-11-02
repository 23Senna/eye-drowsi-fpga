"""Build the FPGA memory files and simulation vectors from the Python owner's export.

Inputs: the CNN team's export (quantize_export.py): <repo>/ml/export/ when this folder is <repo>/integration,
  otherwise ../eye-drowsi-fpga/ml/export/ (override with env TEAM_EXPORT=<dir>):
  conv1_w.mem conv1_b.mem conv2_w.mem conv2_b.mem fc_w.mem fc_b.mem params.txt
  images.mem          N images x 1024 words (24x24 = 576 px + zero pad), uint8, N <= 16
  expected.txt        sw label pred logit0 logit1   (FC class 0 = eye_closed, 1 = eye_open)
  expected_a1.mem     4x11x11 per image, expected_a2.mem 8x4x4 per image
Outputs (padded to 16 slots when the export has fewer images):
  mem/images.mem    16384 x 8 image ROM
  rtl/model_params.vh  `define CNN_S1 / CNN_S2 / CNN_N_IMG (read by testbenches and the datapath)
  mem/weights.mem   580 x 8   0-35 conv1 [f][r][c] | 36-323 conv2 [f2][f1][r][c] | 324-579 fc [class][ch*16+r*4+c]
  mem/biases.mem    14 x 32   0-3 conv1 | 4-11 conv2 | 12-13 fc
  mem/labels.mem    16 x 1    ground truth eye_state (1 = closed)
  mem/stub_logits.mem 16 x 48 {logit0[23:0], logit1[23:0]} golden logits for cnn_core_stub
  mem/seq.mem       64 x 4    sequence-mode slot order (correctly classified slots only)
  sim/vectors/seq_expected.mem  {eye, state} per sequence step (2 laps)
  sim/vectors/drowsy_trace.mem  48-bit {eye,low_conf,count,closed_run,open_run,perclos,state} per step
  sim/vectors/slot_sum.mem      sum of the 576 pixels per slot
  sim/vectors/expected*         copies of the export's golden files (for the testbenches)
  sim/*.mem                     copies of the export's 7 ROM files (cnn_top/rom_weights read them by bare name)
The integer model below re-implements quantize_export.forward() and must match expected*.
Run from anywhere: py -3.11 scripts/gen_sim_data.py
"""
import os
import shutil
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
FPGA = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from drowsy_ref import DrowsyRef, run  # noqa: E402

MEM, VEC = os.path.join(FPGA, "mem"), os.path.join(FPGA, "sim", "vectors")
# team export: <repo>/ml/export when this folder is <repo>/integration, else ../eye-drowsi-fpga/ml/export
_IN_REPO = os.path.join(FPGA, "..", "ml", "export")
EXP = os.environ.get("TEAM_EXPORT", _IN_REPO if os.path.isdir(_IN_REPO)
                     else os.path.join(FPGA, "..", "eye-drowsi-fpga", "ml", "export"))
ROM_FILES = ("conv1_w", "conv1_b", "conv2_w", "conv2_b", "fc_w", "fc_b", "images")
SLOTS, IMG, PAD = 16, 24, 1024     # hardware: 16 slots x 1024 words, 24x24 input


def read_mem(path, bits):
    v = np.array([int(l, 16) for l in open(path) if l.strip()], np.int64)
    return np.where(v >= 1 << (bits - 1), v - (1 << bits), v)


def write(path, words, digits):
    with open(path, "w") as f:
        f.write("\n".join(f"{int(w) & ((1 << 4 * digits) - 1):0{digits}x}" for w in words) + "\n")


def conv(x, w, b):                       # x (C,H,W), w (F,C,3,3) -> (F,H-2,W-2), exact integers
    C, H, W = x.shape
    out = np.zeros((w.shape[0], H - 2, W - 2), np.int64)
    for ky in range(3):
        for kx in range(3):
            out += np.einsum("chw,fc->fhw", x[:, ky:ky + H - 2, kx:kx + W - 2], w[:, :, ky, kx])
    return out + b[:, None, None]


def act(acc, s):
    return np.clip(acc >> s, 0, 127)


def pool(x):
    C, H, W = x.shape
    h, w = H // 2, W // 2
    return x[:, :2 * h, :2 * w].reshape(C, h, 2, w, 2).max(axis=(2, 4))


def main():
    p = dict(l.strip().split("=") for l in open(os.path.join(EXP, "params.txt")) if "=" in l)
    S1, S2 = int(p["S1"]), int(p["S2"])
    w1, b1, w2, b2, wf, bf = (read_mem(os.path.join(EXP, n + ".mem"), 8 if n.endswith("_w") else 32)
                              for n in ("conv1_w", "conv1_b", "conv2_w", "conv2_b", "fc_w", "fc_b"))
    # the RTL (cnn_control, ROM maps) is built for this network: stop loudly if the export changed shape
    shapes = [w1.size, b1.size, w2.size, b2.size, wf.size, bf.size]
    assert shapes == [36, 4, 288, 8, 256, 2],         f"network shape changed (conv1_w/b, conv2_w/b, fc_w/b sizes {shapes}): update cnn_control.v, weight_bias_rom.v and this script"
    w1, w2, wf = w1.reshape(4, 1, 3, 3), w2.reshape(8, 4, 3, 3), wf.reshape(2, 128)
    os.makedirs(VEC, exist_ok=True)
    for name in ("expected.txt", "expected_a1.mem", "expected_a2.mem"):
        shutil.copyfile(os.path.join(EXP, name), os.path.join(VEC, name))
    for name in ROM_FILES:
        shutil.copyfile(os.path.join(EXP, name + ".mem"), os.path.join(FPGA, "sim", name + ".mem"))
    exp = [l.split() for l in open(os.path.join(VEC, "expected.txt")).read().splitlines()[1:] if l.strip()]
    N_IMG = len(exp)
    assert 1 <= N_IMG <= SLOTS, f"{N_IMG} images: hardware has {SLOTS} slots (image_rom, SW[3:0])"
    pix = np.array([int(l, 16) for l in open(os.path.join(EXP, "images.mem")) if l.strip()], np.int64)
    assert pix.size == N_IMG * PAD, f"images.mem has {pix.size} words, expected {N_IMG} x {PAD}"
    imgs = pix.reshape(N_IMG, PAD)[:, :IMG * IMG].reshape(N_IMG, 1, IMG, IMG)
    ea1 = read_mem(os.path.join(VEC, "expected_a1.mem"), 8).reshape(N_IMG, 4, 11, 11)
    ea2 = read_mem(os.path.join(VEC, "expected_a2.mem"), 8).reshape(N_IMG, 8, 4, 4)

    logits, accmax = [], [0, 0, 0]
    for n in range(N_IMG):
        acc1 = conv(imgs[n], w1, b1); a1 = pool(act(acc1, S1))
        acc2 = conv(a1, w2, b2);      a2 = pool(act(acc2, S2))
        lg = wf @ a2.flatten() + bf
        accmax = [max(accmax[0], abs(acc1).max()), max(accmax[1], abs(acc2).max()), max(accmax[2], abs(lg).max())]
        assert (a1 == ea1[n]).all() and (a2 == ea2[n]).all(), f"a1/a2 mismatch image {n}"
        assert [int(exp[n][3]), int(exp[n][4])] == lg.tolist(), f"logit mismatch image {n}"
        logits.append(lg)
    # worst case over any input: |acc| <= sum|w| * max_in + |b|
    bound = [abs(w1).sum((1, 2, 3)).max() * 255 + abs(b1).max(), abs(w2).sum((1, 2, 3)).max() * 127 + abs(b2).max(),
             abs(wf).sum(1).max() * 127 + abs(bf).max()]
    print(f"integer model == export (a1, a2, logits) for {N_IMG} images;  S1 = {S1}  S2 = {S2}")
    print("max |acc| on images conv1/conv2/fc:", accmax, " worst-case bound:", bound,
          " -> bits", [int(v).bit_length() + 1 for v in bound])

    write(os.path.join(MEM, "weights.mem"), np.concatenate([w1.flatten(), w2.flatten(), wf.flatten()]), 2)
    write(os.path.join(MEM, "biases.mem"), np.concatenate([b1, b2, bf]), 8)
    labels = [1 - int(e[1]) for e in exp]                      # eye_state 1 = closed = FC class 0
    preds = [int(lg[0] >= lg[1]) for lg in logits]             # argmax tie -> class 0 (closed)
    pad = SLOTS - N_IMG                                        # unused slots: black image, zero logits
    write(os.path.join(MEM, "images.mem"), np.concatenate([pix, np.zeros(pad * PAD, np.int64)]), 2)
    write(os.path.join(MEM, "labels.mem"), labels + [0] * pad, 1)
    write(os.path.join(MEM, "stub_logits.mem"), [((int(l0) & 0xFFFFFF) << 24) | (int(l1) & 0xFFFFFF)
                                                 for l0, l1 in logits] + [0] * pad, 12)
    write(os.path.join(VEC, "slot_sum.mem"), [int(im.sum()) for im in imgs] + [0] * pad, 5)
    with open(os.path.join(FPGA, "rtl", "model_params.vh"), "w") as f:
        f.write("// model_params.vh - generated by scripts/gen_sim_data.py from mem/export (do not edit)\n"
                f"`define CNN_S1    {S1}\n`define CNN_S2    {S2}\n`define CNN_N_IMG {N_IMG}\n")
    print("labels (1=closed):", labels, " preds:", preds)

    # sequence: only correctly classified slots, 16 mostly open, 24 ~55 % closed, 10 closed, 14 open
    rng = np.random.default_rng(2026)
    ok_open = [s for s in range(N_IMG) if labels[s] == preds[s] == 0]
    ok_closed = [s for s in range(N_IMG) if labels[s] == preds[s] == 1]
    eyes = ([1 if i in (5, 12) else 0 for i in range(16)]
            + [int(v) for v in (rng.random(24) < 0.55)] + [1] * 10 + [0] * 14)
    seq = [int(rng.choice(ok_closed if e else ok_open)) for e in eyes]
    write(os.path.join(MEM, "seq.mem"), seq, 1)
    out = run(eyes * 2)
    write(os.path.join(VEC, "seq_expected.mem"), [(e << 4) | o["state"] for e, o in zip(eyes * 2, out)], 2)
    print("seq states lap 1:", "".join("ADM"[o["state"]] for o in out[:64]))

    # random trace for tb_drowsy_fsm (independent of the CNN)
    ref, words, eyes_t = DrowsyRef(), [], []
    for p_closed, n in [(0.1, 60), (0.5, 80), (0.95, 40), (0.05, 60), (0.45, 120), (1.0, 70), (0.0, 70)]:
        eyes_t += [int(v) for v in (rng.random(n) < p_closed)]
    for e in eyes_t:
        lc = int(rng.random() < 0.08)
        o = ref.step(e, bool(lc))
        words.append((e << 44) | (lc << 40) | (o["count"] << 32) | (o["closed_run"] << 24)
                     | (o["open_run"] << 16) | (o["perclos"] << 8) | o["state"])
    write(os.path.join(VEC, "drowsy_trace.mem"), words, 12)
    print(f"drowsy trace: {len(words)} steps")


if __name__ == "__main__":
    main()
