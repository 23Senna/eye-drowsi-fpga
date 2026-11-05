"""Run the bit-exact integer CNN (same math as cnn_top / gen_sim_data.py) on 24x24 eye crops.

  python tools/check_crops.py --open eye_dataset/open --closed eye_dataset/closed
  python tools/check_crops.py --npz ml/test.npz                 # baseline on the training domain

Prints accuracy per class and the mean / std of the pixels next to the training set, so a
crop-domain shift (framing, brightness, contrast) shows up before the board test.
FC class 0 = closed, 1 = open; prediction = 0 if logit0 >= logit1 (same tie rule as the RTL).
"""
import argparse
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
EXP = ROOT / 'ml' / 'export'


def read_mem(path, bits):
    v = np.array([int(x, 16) for x in path.read_text().split()], np.int64)
    return np.where(v >= 1 << (bits - 1), v - (1 << bits), v)


def conv(x, w, b):
    C, H, W = x.shape
    out = np.zeros((w.shape[0], H - 2, W - 2), np.int64)
    for ky in range(3):
        for kx in range(3):
            out += np.einsum('chw,fc->fhw', x[:, ky:ky + H - 2, kx:kx + W - 2], w[:, :, ky, kx])
    return out + b[:, None, None]


def act(acc, s):
    return np.clip(acc >> s, 0, 127)


def pool(x):
    C, H, W = x.shape
    return x[:, :H // 2 * 2, :W // 2 * 2].reshape(C, H // 2, 2, W // 2, 2).max(axis=(2, 4))


class IntModel:
    def __init__(self, export=EXP):
        p = dict(l.split('=') for l in (export / 'params.txt').read_text().split())
        self.s1, self.s2 = int(p['S1']), int(p['S2'])
        m = {n: read_mem(export / f'{n}.mem', bits) for n, bits in
             [('conv1_w', 8), ('conv1_b', 32), ('conv2_w', 8), ('conv2_b', 32), ('fc_w', 8), ('fc_b', 32)]}
        self.w1, self.b1 = m['conv1_w'].reshape(4, 1, 3, 3), m['conv1_b']
        self.w2, self.b2 = m['conv2_w'].reshape(8, 4, 3, 3), m['conv2_b']
        self.wf, self.bf = m['fc_w'].reshape(2, 128), m['fc_b']

    def logits(self, pixels):
        x = np.asarray(pixels, np.int64).reshape(1, 24, 24)
        a1 = pool(act(conv(x, self.w1, self.b1), self.s1))
        a2 = pool(act(conv(a1, self.w2, self.b2), self.s2))
        return self.wf @ a2.flatten() + self.bf

    def predict(self, pixels):
        l0, l1 = self.logits(pixels)
        return int(l0 < l1), int(l0), int(l1)      # 1 = open


TRAIN_MEAN, TRAIN_STD = 79.7, 15.7      # ml/train.npz pixel mean / per-image std (printed by main)


def match_train(x):
    """Shift/scale one crop to the training set's brightness and contrast (PC side, before upload)."""
    x = np.asarray(x, np.float64)
    y = (x - x.mean()) / max(x.std(), 1.0) * TRAIN_STD + TRAIN_MEAN
    return np.clip(np.rint(y), 0, 255).astype(np.uint8)


def load_dir(d):
    from PIL import Image
    files = sorted(p for p in Path(d).iterdir() if p.suffix.lower() in ('.png', '.jpg', '.jpeg', '.bmp'))
    imgs = []
    for f in files:
        with Image.open(f) as im:
            imgs.append(np.asarray(im.convert('L').resize((24, 24), Image.Resampling.BOX), np.uint8))
    return np.array(imgs).reshape(-1, 24, 24), files


def report(name, model, X, label):
    if len(X) == 0:
        print(f'{name}: no images'); return 0, 0
    preds = np.array([model.predict(x)[0] for x in X])
    ok = int((preds == label).sum())
    print(f'{name:>7}: {ok}/{len(X)} correct ({100 * ok / len(X):.0f} %)   '
          f'pixel mean {X.mean():5.1f}  std {X.reshape(len(X), -1).std(1).mean():5.1f}')
    return ok, len(X)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--open', help='folder of open-eye crops')
    ap.add_argument('--closed', help='folder of closed-eye crops')
    ap.add_argument('--npz', help='npz with X (N,24,24) uint8 and y (0 closed, 1 open)')
    a = ap.parse_args()
    model = IntModel()
    tr = np.load(ROOT / 'ml' / 'train.npz')['X']
    print(f'training set: pixel mean {tr.mean():5.1f}  std {tr.reshape(len(tr), -1).std(1).mean():5.1f}')
    sets = []
    if a.npz:
        d = np.load(a.npz)
        sets += [('closed', d['X'][d['y'] == 0], 0), ('open', d['X'][d['y'] == 1], 1)]
    if a.closed:
        sets.append(('closed', load_dir(a.closed)[0], 0))
    if a.open:
        sets.append(('open', load_dir(a.open)[0], 1))
    if not sets:
        ap.error('give --npz or --open/--closed')
    for title, f in [('as captured', lambda x: x), ('--norm (match_train)', match_train)]:
        print(title)
        tot = [0, 0]
        for name, X, label in sets:
            ok, n = report(name, model, np.array([f(x) for x in X]), label)
            tot[0] += ok; tot[1] += n
        print(f'  total: {tot[0]}/{tot[1]} = {100 * tot[0] / max(tot[1], 1):.1f} %')


if __name__ == '__main__':
    main()
