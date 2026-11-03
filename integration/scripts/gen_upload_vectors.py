"""Generate uploaded pixels and independent integer/temporal expectations."""
from pathlib import Path
import binascii
import numpy as np
from gen_sim_data import EXP, VEC, read_mem, conv, act, pool, write
from drowsy_ref import DrowsyRef


def main():
    export = Path(EXP)
    params = dict(line.split('=') for line in (export/'params.txt').read_text().splitlines())
    w1, b1, w2, b2, wf, bf = [read_mem(export/(n+'.mem'), bits) for n, bits in
        [('conv1_w',8),('conv1_b',32),('conv2_w',8),('conv2_b',32),('fc_w',8),('fc_b',32)]]
    w1, w2, wf = w1.reshape(4,1,3,3), w2.reshape(8,4,3,3), wf.reshape(2,128)
    original = np.array([int(v,16) for v in (export/'images.mem').read_text().split()]).reshape(16,1024)[:,:576]
    expected = [list(map(int,l.split())) for l in (export/'expected.txt').read_text().splitlines()[1:]]
    closed = next(i for i,_,p,*_ in expected if p==0)
    opened = next(i for i,_,p,*_ in expected if p==1)
    frames = list(original) + [np.arange(576)%256, np.zeros(576,dtype=int), np.full(576,255)]
    frames += [original[closed]]*8 + [original[opened]]*10
    logits, warnings = [], []
    ref = DrowsyRef()
    for i, pixels in enumerate(frames):
        a1 = pool(act(conv(pixels.reshape(1,24,24),w1,b1),int(params['S1'])))
        a2 = pool(act(conv(a1,w2,b2),int(params['S2'])))
        l0,l1 = map(int,wf@a2.flatten()+bf)
        if i<16:
            assert [l0,l1]==expected[i][3:5]
        logits.append(((l0 & 0xffffffff)<<32)|(l1 & 0xffffffff))
        warnings.append(ref.step(int(l0>=l1),False)['state'])
    write(Path(VEC)/'upload_pixels.mem',np.array(frames).flatten(),2)
    write(Path(VEC)/'upload_crc.mem',[binascii.crc_hqx(bytes(map(int,p)),0xffff) for p in frames],4)
    write(Path(VEC)/'upload_logits.mem',logits,16)
    write(Path(VEC)/'upload_warnings.mem',warnings,1)
    print(f'Upload vectors: {len(frames)} frames; 16 original + 3 synthetic + 18 temporal frames')


if __name__=='__main__':
    main()
