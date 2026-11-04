"""Batch-one exact integer CPU CNN benchmark versus an explicit FPGA cycle count.

No camera, UART or training is started. This is a NumPy int32 software baseline,
not a claim about the fastest available CPU/INT8 inference runtime.
"""
import os

# Set before NumPy import; int32 matmul uses NumPy's integer kernel, not BLAS.
for name in ('OMP_NUM_THREADS', 'OPENBLAS_NUM_THREADS', 'MKL_NUM_THREADS'):
    os.environ[name] = '1'

import argparse
import datetime
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import time
import numpy as np
from live_audit import Reference, read_mem

ROOT = Path(__file__).resolve().parents[1]


class CpuCNN:
    def __init__(self, ref):
        self.w1 = ref.w1.reshape(4, 9).astype(np.int32).T.copy()
        self.w2 = ref.w2.reshape(8, 36).astype(np.int32).T.copy()
        self.wf = ref.wf.astype(np.int32)
        self.b1, self.b2, self.bf = [b.astype(np.int32) for b in (ref.b1, ref.b2, ref.bf)]
        self.s1, self.s2 = ref.s1, ref.s2
        # Prove accumulators cannot overflow int32 for the allowed input range.
        for w, b, maximum in ((ref.w1, ref.b1, 255), (ref.w2, ref.b2, 127), (ref.wf, ref.bf, 127)):
            bounds = np.abs(w).reshape(len(b), -1).sum(axis=1) * maximum + np.abs(b)
            if np.any(bounds > np.iinfo(np.int32).max):
                raise ValueError('Export exceeds safe int32 accumulator range')

    @staticmethod
    def layer(x, w, b, shift):
        c, h, width = x.shape
        windows = np.lib.stride_tricks.sliding_window_view(x, (3, 3), axis=(1, 2))
        patches = windows.transpose(1, 2, 0, 3, 4).reshape(-1, c * 9)
        acc = (patches @ w + b).T.reshape(len(b), h - 2, width - 2)
        activation = np.clip(acc >> shift, 0, 127)
        ph, pw = activation.shape[1] // 2, activation.shape[2] // 2
        return activation[:, :2*ph, :2*pw].reshape(len(b), ph, 2, pw, 2).max(axis=(2, 4))

    def forward(self, image):
        # Input is a ready 24x24 uint8 eye. Conversion/patch packing/allocations
        # are INCLUDED, along with convolutions, requantization, pools, FC/argmax.
        x = image.astype(np.int32).reshape(1, 24, 24)
        a1 = self.layer(x, self.w1, self.b1, self.s1)
        a2 = self.layer(a1, self.w2, self.b2, self.s2)
        logits = self.wf @ a2.reshape(-1) + self.bf
        l0, l1 = int(logits[0]), int(logits[1])
        return l0, l1, int(l1 > l0)


def describe(values):
    return {name: float(value) for name, value in zip(
        ('median_us', 'p05_us', 'p95_us', 'min_us', 'mean_us'),
        (np.median(values), np.percentile(values, 5), np.percentile(values, 95), np.min(values), np.mean(values)))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--samples', type=int, default=5000, help='Timed batch-one inferences per repeat')
    parser.add_argument('--repeats', type=int, default=5)
    parser.add_argument('--warmup', type=int, default=300)
    parser.add_argument('--fpga-cycles', type=int, default=7996)
    parser.add_argument('--clock-hz', type=float, default=100_000_000)
    args = parser.parse_args()
    if min(args.samples, args.repeats, args.warmup, args.fpga_cycles) < 1 or not args.clock_hz > 0:
        parser.error('All parameters must be positive')
    export = ROOT / 'ml/export'
    ref = Reference(export)
    cpu = CpuCNN(ref)
    pixels = read_mem(export/'images.mem', 16).astype(np.uint8)
    expected = [line.split() for line in (export/'expected.txt').read_text().splitlines()[1:] if line.strip()]
    count = len(expected)
    stride = len(pixels) // count
    if len(pixels) % count or stride < 576:
        raise ValueError('Unsupported exported image layout')
    images = np.stack([pixels[i*stride:i*stride+576].reshape(24,24) for i in range(count)])
    for i, row in enumerate(expected):
        actual = cpu.forward(images[i])
        if actual != (int(row[3]), int(row[4]), int(row[2])):
            raise AssertionError(f'Exported golden mismatch at slot {i}: {actual}')
    rng = np.random.default_rng(20261104)
    for i in range(64):
        image = rng.integers(0,256,(24,24),dtype=np.uint8)
        if cpu.forward(image)[:2] != ref.logits(image.tobytes()):
            raise AssertionError(f'Random golden mismatch {i}')
    print(f'Correctness PASS: {count} exported inputs + 64 deterministic random inputs', flush=True)
    for i in range(args.warmup):
        cpu.forward(images[i % count])
    rounds, all_times = [], []
    checksum = 0
    for repeat in range(args.repeats):
        durations = np.empty(args.samples, dtype=np.float64)
        for i in range(args.samples):
            image = images[i % count]  # Input selection is outside timing.
            start = time.perf_counter_ns()
            result = cpu.forward(image)
            end = time.perf_counter_ns()
            durations[i] = (end-start)/1000
            checksum += result[0] + result[1]
        rounds.append(describe(durations))
        all_times.append(durations)
        print(f'Repeat {repeat+1}: median {rounds[-1]["median_us"]:.3f} us',flush=True)
    stats = describe(np.concatenate(all_times))
    fpga_us = args.fpga_cycles/args.clock_hz*1e6
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r'HARDWARE\DESCRIPTION\System\CentralProcessor\0') as key:
            cpu_name = winreg.QueryValueEx(key, 'ProcessorNameString')[0].strip()
    except (ImportError,OSError):
        cpu_name = platform.processor()
    try:
        power = subprocess.check_output(['powercfg','/getactivescheme'],text=True).strip()
    except (OSError,subprocess.CalledProcessError):
        power = 'unavailable'
    report = {
        'timestamp_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'cpu':cpu_name,'os':platform.platform(),'python':sys.version,'numpy':np.__version__,
        'power_scheme':power,'batch_size':1,'cpu_backend':'NumPy int32 matmul, vectorized patch packing',
        'thread_environment':{k:os.environ[k] for k in ('OMP_NUM_THREADS','OPENBLAS_NUM_THREADS','MKL_NUM_THREADS')},
        'samples_per_repeat':args.samples,'repeats':args.repeats,'warmup':args.warmup,
        'correctness':{'exported_inputs':count,'random_inputs':64,'exact_logits_match':True},
        'cpu_timing':stats,'repeat_stats':rounds,'checksum':checksum,
        'fpga':{'cycles':args.fpga_cycles,'clock_hz':args.clock_hz,'inference_us':fpga_us,
                'source':'Cycle count from previously validated FPGA telemetry, not a new physical measurement'},
        'speedup_cpu_median_over_fpga':stats['median_us']/fpga_us,
        'export_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(export.glob('*.mem'))
                         if p.stem in ('conv1_w','conv1_b','conv2_w','conv2_b','fc_w','fc_b','images')},
        'limitations':[
            'Exact numerical integer CNN baseline; not a native optimized INT8 runtime or best possible CPU performance.',
            'CPU includes uint8->int32 conversion, patch packing, intermediate allocation and Python dispatch.',
            'Both sides exclude image preprocessing, file loading, UART, display and model/weight initialization.',
            'No CPU affinity or power/frequency lock; power mode and background workload affect results.',
            'Speedup applies only to this backend and host configuration, not all software/CPUs.'
        ]}
    folder = ROOT/'build/benchmarks'/datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    folder.mkdir(parents=True)
    (folder/'report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    np.save(folder/'cpu_times_us.npy',np.concatenate(all_times))
    summary = (f'CPU: {cpu_name}\nNumPy integer CNN, batch 1\n'
               f'CPU median: {stats["median_us"]:.3f} us\nCPU p95: {stats["p95_us"]:.3f} us\n'
               f'FPGA: {fpga_us:.3f} us ({args.fpga_cycles} cycles at {args.clock_hz:g} Hz)\n'
               f'CPU median / FPGA: {stats["median_us"]/fpga_us:.3f}x\n'
               'FPGA value uses previous telemetry; not a new board run.\n'
               'This is a NumPy int32 baseline, not a claim about optimized INT8 runtimes.\n')
    (folder/'summary.txt').write_text(summary,encoding='utf-8')
    print(summary)
    print('Evidence:',folder)


if __name__ == '__main__':
    main()
