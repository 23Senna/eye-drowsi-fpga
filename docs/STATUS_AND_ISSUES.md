# Current status and known issues

Reviewed 2026-11-04 against team main `e3ac7ea` (merged webcam GUI PR #11).
This page is the current index. [STUDY_PROGRESS.md](STUDY_PROGRESS.md) is a
dated journal; pending/uncommitted statements describe their original sessions.
The [previous status snapshot](archive/STATUS_20261103.md) remains historical.

## Implemented

- Basys 3 integer CNN: 24x24 grayscale, Conv 1->4, Conv 4->8, FC 128->2;
  int8 weights, signed int32 logits, S1=10/S2=6. Filter-parallel lanes 4/8/2.
  Inference: **712 cycles = 4.75 us at 150 MHz** (5 Nov `cnn150` core; 100 MHz core 702 cycles = 7.02 us).
- ROM slots, board sequence controls, observation-count drowsiness FSM,
  LED/display and JA1 buzzer.
- 1 Mbaud 8N1 UART (115200 before 5 Nov) telemetry and CRC-checked 576-byte external image uploads.
- Host webcam preprocessing and persistent UART, integrated into Windows GUI.
  Live defaults: left eye, Reyn eye+brow, pad 0.15, contrast 60..235,
  vertical offset +0.10, target 10 Hz. MediaPipe/crop run on the laptop;
  CNN classification and warning decisions run on FPGA.

## Evidence and scope

| Area | Evidence | Limit |
|---|---|---|
| CNN numerical behavior | Recorded RTL regressions match 16 exported logit pairs; two demo images are known model misses (14/16 labels correct) | Numerical agreement is not unseen-subject accuracy |
| UART faults/recovery | [CRC, timeout, reset and operator logs](../integration/docs/IMAGE_UPLOAD_VERIFICATION.md) | 3 Nov archive uses older 37,290-cycle core |
| Current implementation | [9dac154 build archive](reports/current_build_20261104/README.md): setup +0.948 ns, hold +0.067 ns; 2,376 LUT / 2,230 FF / 7.5 BRAM / 14 DSP | Exact top/build, not all historical reports |
| Host and GUI | 30 host tests and Release GUI bridge smoke pass; [selected logs](reports/current_build_20261104/README.md) | Smoke uses mock backend, not physical camera/board |
| Physical GUI | Operator reports integrated GUI passed with Reyn/+0.10 webcam configuration | Operator attestation; no new raw sequence/video supplied |
| CPU comparison | [NumPy integer baseline](../integration/docs/INFERENCE_BENCHMARK.md): 152.8 us median vs 79.96 us FPGA, 1.911x | Specific CPU/backend/power configuration; prior FPGA telemetry |

The team repository is the implementation source of truth. The separate local
FPGA_Final_Project assignment workspace is learning material and historical
audits, not another deployed source tree.

## Open limitations

1. Live client stops after frame ID 65535. Stop, reset btnU and restart with
   a new ID range; automatic rollover and diagnostic filename handling remain future work.
2. Temporal thresholds count observations, not measured closure time. Missing
   or late observations pause the host. Reset with UART idle before resuming;
   stopping the host does not clear a latched board alarm.
3. Accuracy 98.15% (108 test images) is from a small single-subject dataset,
   with possible neighbouring-frame leakage. Subject-disjoint evaluation and
   more people/lighting/pose/camera tests remain needed.
4. Slots 0/1 are known model misses. Confidence margin 1024 is uncalibrated;
   SW13 can hold the previous eye state. Keep it down for the live demo.
5. Standalone basys3_wrapper is separate from the tested integration top.
   Use integration/ for UART, webcam and buzzer demonstrations.
6. ML dependency versions and training seed were not frozen. Retraining is
   possible from committed crops but is not guaranteed to reproduce identical
   weights; raw Roboflow folders require a separate download.
7. Code license remains a team decision. Dataset attribution is separate:
   [ml/README.md](../ml/README.md).
8. No public release package/video is claimed here. Bitstreams stay outside
   Git; publish source-identified release assets deliberately.

## Start here

- [Setup and demo](GETTING_STARTED.md)
- [Architecture](ARCHITECTURE.md) and [active interface](../integration/docs/INTERFACE.md)
- [Evidence index](reports/README.md)
- [Repository and artifact policy](REPOSITORY_POLICY.md)
