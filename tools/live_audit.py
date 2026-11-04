"""Compare exact uploaded pixels with the exported integer CNN, never override FPGA results."""
import hashlib
from pathlib import Path
import sys
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'integration/scripts'))
from gen_sim_data import conv, act, pool


def read_mem(path,bits):
    values=np.array([int(word,16) for word in Path(path).read_text().split()],dtype=np.int64)
    return np.where(values >= 1 << (bits-1),values-(1 << bits),values)


class Reference:
    def __init__(self, export=ROOT/'ml/export'):
        export=Path(export)
        params=dict(line.split('=') for line in (export/'params.txt').read_text().splitlines())
        self.s1,self.s2=int(params['S1']),int(params['S2'])
        w1,self.b1,w2,self.b2,wf,self.bf=[read_mem(export/(n+'.mem'),bits) for n,bits in
            [('conv1_w',8),('conv1_b',32),('conv2_w',8),('conv2_b',32),('fc_w',8),('fc_b',32)]]
        self.w1,self.w2,self.wf=w1.reshape(4,1,3,3),w2.reshape(8,4,3,3),wf.reshape(2,128)

    def logits(self,pixels):
        if len(pixels)!=576:raise ValueError('Expected 576 pixels')
        x=np.frombuffer(pixels,dtype=np.uint8).astype(np.int64).reshape(1,24,24)
        a1=pool(act(conv(x,self.w1,self.b1),self.s1))
        a2=pool(act(conv(a1,self.w2,self.b2),self.s2))
        return tuple(map(int,self.wf@a2.flatten()+self.bf))


class Audit:
    def __init__(self,directory):
        self.directory=Path(directory)
        self.directory.mkdir(parents=True,exist_ok=True)
        self.reference=Reference()

    def __call__(self,frame_id,pixels,result):
        path=self.directory/f'{frame_id:05d}.raw'
        with path.open('xb') as output:output.write(pixels)
        l0,l1=self.reference.logits(pixels)
        return {'input_raw':str(path),'input_sha256':hashlib.sha256(pixels).hexdigest(),
                'golden_logit0':l0,'golden_logit1':l1,
                'golden_class':'OPEN' if l1>l0 else 'CLOSED',
                'golden_match':(l0,l1)==(result['logit0'],result['logit1'])}
