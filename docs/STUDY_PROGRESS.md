# Development Progress

## 2026-11-04: Team GUI integrated with validated live UART client

Preserved local work on codex/live-webcam-gui and merged origin/main 7fced1e (team GUI 10 FPS, --quiet CLI, updated eye/eyebrow recorder). Resolved eye_capture.py preserving upstream --record/CAMERA status and the validated crop API, contrast and offset support. The Windows live button now runs one .venv-camera client with camera selection, left eye, 10 Hz target, Reyn crop, offset +0.10 and diagnostics. Replaced file-directory uploads with direct latest-frame/persistent-UART transport. GUI reads structured LIVE_EVENT messages, displays FPGA results and exact completed raw crop, updates frame ID, marks stale/gap status and supports idle-reset-resume. Stop/close sends STOP and drains the worker; 10-second fallback termination requires reset. The OpenCV camera/ROI windows remain separate from the Windows result/crop panel.

Thirty Python host tests PASS. .NET 8 Release build PASS with zero warnings/errors using an isolated official SDK under build/dotnet-sdk. GUI bridge smoke PASS with a mock child backend (no physical camera/COM): exact crop/result rendering, frame-ID propagation, stale-result clearing, resume availability and START/STOP child lifecycle. Screenshot and smoke result retained under build/gui_integration. User previously reported good physical webcam results for the unchanged Reyn/+0.10 preprocessing; the newly integrated GUI still needs operator physical validation. No FPGA/weights/bitstream change and no push/PR performed in this task. Personal test3.jpg remains untracked and excluded from commits.

## 2026-11-04: Lower-eye context in live cropping

At the operator's request, live reyn mode now shifts the ROI downward by 10% of the crop side to include more skin below the eye. Added --crop-offset-y (-0.5..0.5, positive down), preview and session metadata. Crop size, 24x24 output and contrast remapping are preserved. Other styles/standalone recorder keep zero default shift. Twenty-nine host tests PASS, including downward ROI translation and adjusted-pixel preservation into the UART mailbox. Actual framing remains for operator review.

## 2026-11-04: Reyn preprocessing connected to live UART

live_webcam.py now defaults to --roi-style reyn: the recorder's shared eye/eyebrow crop with padding 0.15, INTER_AREA 24x24 and single contrast remapping to 60..235. The adjusted 576 bytes enter the existing UART mailbox directly and feed diagnostic capture/golden comparison. Preview/startup and session logs identify the active settings; phone and legacy remain available without contrast remapping. FPGA CNN/temporal results remain authoritative; recorder EAR decisions/timers are not substituted. Twenty-nine host tests PASS, including a two-frame mocked live run verifying the default adjusted bytes reach the UART mailbox unchanged. Actual webcam/board accuracy remains for operator testing; weights, RTL and bitstream are unchanged.

## 2026-11-04: Reyn recorder adjustments

Applied the operator-supplied eye_capture.py revision: eye-plus-eyebrow crop with 0.15 margin, 24x24 grayscale, contrast range 60..235, six-landmark EAR, adjustable 0.21 threshold, both-eyes closure timers (0.7s DROWSY, 1.5s SLEEPING), panel and heuristic-labelled PNGs. Corrected the supplied _name_/_main_ typo, retained --out-dir, added --camera, moved directory creation into main, used monotonic timing and guaranteed loop resource cleanup. Preserved crop_eye compatibility for the live phone/legacy client despite the new six-point constants. Recorder EAR status/labels are computed on the laptop; this does not change FPGA predictions, the UART client's current preprocessing, weights or bitstream.

## 2026-11-04: Wider crop becomes the live default

At the operator's request, live_webcam.py now defaults to the calibrated phone-style crop (1.90 eye widths rather than legacy 1.35, about 41% wider). It includes more eyebrow and skin while preserving the 24x24 grayscale UART payload. Startup and preview show the active style/width to distinguish runs. Explicit --roi-style legacy still selects the earlier framing; standalone eye_capture.py remains compatible. This applies the existing phone calibration, not an additional enlargement beyond that preset. Live accuracy still needs operator verification; FPGA weights/bitstream are unchanged.

## 2026-11-04: Phone-style live ROI calibration

Diagnostic session 20261104_134400_309737 contains 593 checked results with exact raw-payload hashes and matching integer golden logits. Stable operator-labelled samples (excluding one second after label changes) give OPEN 27/27 correct and CLOSED 0/41 correct. This establishes a visual-classification problem for these samples despite numerical FPGA agreement.

Registered three manual phone crops against their original photos to measure framing, then added optional --roi-style phone: 1.90 eye-width square, anchored to eye corners, shifted upward 0.16 and outward 0.10 eye widths. Default legacy behavior remains available. On the same phone originals both automatic modes classify OPEN correctly; legacy classifies both CLOSED eyes as OPEN while phone mode returns CLOSED for both. These reused calibration photos do not establish webcam/generalization accuracy. Local private comparison artifacts remain ignored under local_inputs/phone_eyes/2026-11-03/preprocessed/. Twenty-six host tests PASS, including stable corner anchoring and legacy crop compatibility. Live operator validation is next; no RTL, weights, thresholds or bitstream changes were made.

## 2026-11-04: Live CLOSED misclassification investigation

Operator screenshots show a tracked, visibly closed selected eye with OPEN telemetry. Existing sessions contain both OPEN and CLOSED predictions and no serial errors, but no pixels/ground-truth labels were recorded, so the screenshot cannot be matched to an exact inferred input. Added opt-in --diagnostics: exact uploaded raw pixels and SHA256 per frame ID, independent integer golden comparison, visual input for the completed result, and O/C/U operator labels. A numerical mismatch stops sending without altering reported FPGA classes. Preserved default crop padding (0.35), exposed --pad for later labelled comparisons, and replaced instantaneous capture-derived Hz with averaged send-derived Hz. Twenty-four host tests PASS, including all 16 exported golden pairs, raw-byte preservation and mismatch stop behavior. Root cause/visual accuracy remains pending labelled diagnostic capture; no model weights, RTL, or class thresholds were changed.

## 2026-11-04: Current-main webcam demonstration bitstream

Fetched origin again and verified local main equals origin/main at 9dac15469da453cfe3ea5340ca7ef9e3e25fcf72 (PR #10 buzzer), zero commits ahead/behind. Built current parallel CNN + UART upload + buzzer at 100 MHz: build/uart_hw_20261104_131740/drowsiness_top.bit, setup +0.948 ns and hold +0.067 ns. Build input fingerprints and bitstream SHA256 are retained alongside the reports. This new build has not been programmed or physically validated in this session. The live host changes remain uncommitted; private local inputs are preserved and ignored.

## 2026-11-04: Live external webcam client

Implemented tools/live_webcam.py and live_transport.py: selected-eye MediaPipe crops, persistent CRC UART uploads on a worker thread, latest-frame replacement, bounded freshness, target pacing, responsive OpenCV preview, stale/gap pause, frame IDs and timestamped JSONL session evidence. No new FPGA interface is required; both historical and current latency fields are accepted. Added isolated .venv-camera (Python 3.12.14, numpy 1.26.4, opencv-contrib-python 4.11.0.86, MediaPipe 0.10.21, pySerial 3.5); dependency check PASS. Twenty host tests PASS in the camera environment plus one separate headless preview lifecycle test PASS. Actual CAMTECH CT-30 on camera index 0 opened at 640x480; 12/12 probe frames produced valid 24x24 eye crops, with no images/video saved. Probe metadata and installed packages are in build/live_webcam_validation/. Existing COM enumeration showed only Bluetooth ports, so live camera-to-FPGA hardware throughput and warning behavior remain unverified in this implementation session. Fixed the missing buzzer source in verify_uart.py; tb_top now PASS (16 slots, 128 sequence frames). Usage and manual reset/resume limitations: integration/docs/LIVE_WEBCAM.md. Changes remain local; no commit/push/merge performed for this feature.

## 2026-11-03: Team PR preparation and upstream integration

Created codex/uart-image-upload and integrated current team main 56c0237 without conflicts, preserving the upstream documentation, shift guard, stub default and core testbench fixes. After integration, 16 host tests and four targeted Icarus checks PASS; xsim independently passes the 37-frame real upload test and 87-result legacy real-UART test. A fresh 100 MHz build (build/uart_hw_20261103_150217) reproduces setup +1.273 ns, hold +0.037 ns, 1677 LUT, 1639 FF, 7 BRAM tiles and 3 DSP. This rebuild has not been physically programmed in this session. Selected original and post-integration reports, source hashes, simulation logs, operator captures, and two non-ROM demo crops are archived under docs/reports/uart_image_upload_20261103/ for team review. Large generated build directories/bitstreams remain ignored. Current verification scope and physical observations are consolidated in integration/docs/IMAGE_UPLOAD_VERIFICATION.md; earlier pending statements below are historical.

## 2026-11-03: Physical upload fault checks and recovery

Inspected the three operator-run COM6 checker logs and summaries: CRC corruption (ID 100) returns ERR CRC; partial transfer (ID 200, 64/576 pixels) returns ERR TIMEOUT; operator-held btnU reset aborts partial ID 300. All three reject RUN_FRAME with ERR NOFRAME and report no RESULT during the checked quiet interval. Fresh uploads 101/201/301 then match OPEN golden logits -17106/17976 and 37290 cycles / 372 us. All three checker summaries are PASS. Evidence: build/physical_upload_crc_20261103_144833_159064/, build/physical_upload_timeout_20261103_144913_782654/, build/physical_upload_reset_20261103_144946_468206/; consolidated index: build/hardware_uart_upload_faults/summary.json. Reset timing is operator-attested; no internal cnn_start probe or independent bitstream readback was performed.

## 2026-11-03: Operator uploaded OPEN recovery

Validated the attached COM6 capture: all 32 OPEN uploads (frame IDs 12-43), acknowledgements, logits -24956/25692, and 37290 cycles / 372 us match. DrowsyRef continuing from the prior eight CLOSED observations matches every warning: MICROSLEEP through ID 20, DROWSY at ID 21, AWAKE at ID 37. No ERR line is present. Together, supplied CLOSED/recovery captures cover 40 consecutive observations with zero numerical/temporal mismatches. Raw attachment and summary: build/hardware_uart_upload_recovery/. This is operator-provided evidence of frame-count behavior; timing cadence and bitstream identity are not independently measured.

## 2026-11-03: Operator uploaded CLOSED sequence

Eight user-supplied COM6 upload records (frame IDs 4-11) all match CLOSED golden logits 8884/-9142 and 37290 cycles / 372 us. With the instructed reset as the reference initial state, DrowsyRef matches all warnings: seven AWAKE observations followed by MICROSLEEP on the eighth. Evidence: build/hardware_uart_upload_closed_sequence/. This validates observation-count behavior in the supplied capture; sampling cadence and elapsed closure duration were not measured. Recovery remains pending.

## 2026-11-03: Operator uploads of non-ROM images

User-supplied COM6 records for eye_closed.png (frame_id=2) and eye_open.png (frame_id=3) match their independent integer references exactly: CLOSED 8884/-9142 and OPEN -24956/25692. Both report source=UPLOAD, AWAKE, 37290 cycles / 372 us. Both pixel arrays were checked absent from the 16 stored ROM images. Evidence: build/hardware_uart_upload_new_images/serial.log and summary.json; image provenance/goldens: build/uart_upload_demo/expected.json. This demonstrates operator-observed external-image inference for these two crops; it does not establish continuous-camera accuracy, sampling cadence, electrical robustness, or independently identify the programmed bitstream.

## 2026-11-03: First operator image-upload observation

User-supplied COM6 output shows LOAD/CRC acknowledgement and one source=UPLOAD result for frame_id=1, using host export slot 3. Class OPEN and logits -17106/17976 match the committed golden; latency is 37290 cycles / 372 us. Capture retained in build/hardware_uart_upload_first/. This is operator-provided evidence; the excerpt alone does not independently identify the programmed bitstream. Prepared two test-set PNG eye crops absent from all 16 ROM images in build/uart_upload_demo/ with integer golden logits; their physical upload checks remain pending.

## 2026-11-03: UART image upload implementation

- Implemented CRC-checked 576-byte binary image reception, synchronous staging RAM, explicit frame-ID run, source latching, and upload-aware ownership/backpressure. ROM and board controls remain available; CNN arithmetic and weights are unchanged.
- Added Python upload support for exact raw/.mem pixels and grayscale/resized PNG/JPEG eye crops. Installed Pillow 12.3.0 only in the local virtual environment. Twelve host tests PASS.
- Resolved 23 simulation configurations across final Icarus runs and xsim; 37 real-CNN upload frames match integer/temporal references, and xsim independently confirms upload plus 87 legacy real-UART results.
- Final 100 MHz implementation: setup +1.273 ns, hold +0.037 ns, 1,677 LUT, 1,639 FF, 7 BRAM tiles, 3 DSP. Generated build/uart_hw_20261103_140549/drowsiness_top.bit; source hashes and raw evidence retained.
- Physical tests remain pending: current port enumeration identifies only Bluetooth ports. No board programming, commit, or push performed. Details and limitations: integration/docs/IMAGE_UPLOAD_VERIFICATION.md.

## 2026-11-02 UART control and telemetry

Base revision: e9bc475; development branch: feature/uart. Source changes are not committed or pushed.

- Implemented 115200 8N1 UART, ASCII SLOT/RUN protocol and complete RESULT records.
- Added synchronized/debounced SW9 ownership, deferred mode changes and lossless result backpressure.
- Preserved CNN arithmetic/exports and existing board display/temporal behavior.
- Added a Python command-line client with pySerial 3.5 and five passing host tests.
- Reproduced 11 baseline tests; final regression passes 18 configurations, including real-CNN serial-pin tests over all 16 slots and timed sequences.
- Implemented/routed at 100 MHz: setup +2.052 ns, hold +0.033 ns; 1,372 LUT, 1,408 registers, 6.5 BRAM and 3 DSP. Bitstream generated successfully.
- Physical board UART validation remains pending: only Bluetooth serial ports were identified on the test PC. No board was programmed.

See integration/docs/UART.md for the protocol and board checklist, and integration/docs/UART_VERIFICATION.md for exact evidence paths, warnings and limitations. Next milestone: record a build-identified physical serial/board demonstration and archive its logs/video.

## 2026-11-02: Upstream fixed-point synchronization

- Fast-forwarded feature/uart to f9654aa and reapplied the preserved UART work without conflicts. Retained an external file backup and a local stash. No project commit/push.
- Adopted upstream S2=6 and complete export. Preserved the ASCII UART contract and CONF_MARGIN=1024.
- Resolved 22 simulation checks, including a targeted FC-reference repair/retest, 16/16 new golden logit pairs and 87 real/stub UART results each. Core shell regression and five host tests PASS.
- Fixed stale S2=7 vectors and stale FC constants. Tests reject missing/unknown vectors. Added the three upstream layer tests and a missing-vector negative test.
- Fresh 100 MHz build: setup +1.511 ns, hold +0.049 ns, 1,372 LUT, 1,405 FF, 6.5 BRAM, 3 DSP. New bitstream is build/uart_hw_20261102_155516/drowsiness_top.bit.
- Follow-up physical evidence confirmed the earlier build on COM6: PC runs, board-button monitoring and a 70-result sequence. These observations do not validate the new fixed-point bitstream; repeat the physical acceptance checklist with the new build.
- Remaining model-owner work: calibrate low-confidence threshold and synchronize the exporter source/metadata. No threshold or invented dequantization change was introduced.

## 2026-11-02: Physical validation of the updated UART build

User-supplied COM6 terminal output confirms PC runs for slots 0-9 (10 records) and board-button monitoring for slots 0-15 (16 records). All 26 supplied records match the f9654aa golden logits and predicted classes. Every supplied record reports 37,290 cycles / 372 us and AWAKE. No UART error or malformed record appears in the supplied excerpt. The operator previously reported programming build/uart_hw_20261102_155516/drowsiness_top.bit; the new slot-3 logits also distinguish it from the old export. This is operator-provided hardware evidence, not an independently instrumented observation or an exhaustive UART robustness test.

Remaining physical checks: updated-build sequence and warning recovery, PC runs for slots 10-15, SW13 hold, reset during an active transaction and ownership handover during output. Slots 0/1 remain known model classification misses relative to ground truth, despite matching the numerical golden reference.

## 2026-11-02: Updated-build physical sequence capture

Validated an operator-supplied COM6 terminal capture containing 105 complete SEQ records against the f9654aa export and DrowsyRef initialized from reset. All 105 slot positions, golden logit pairs, raw classes, temporal warning states and latency fields match. Each record reports 37,290 cycles / 372 us. No ERR line or malformed RESULT appears in the supplied capture.

Warning transitions (one-based capture frame): 1 AWAKE, 36 DROWSY, 47 MICROSLEEP, 60 DROWSY, 78 AWAKE, 100 DROWSY. The capture includes one full 64-frame loop and 41 frames of the next loop, including full MICROSLEEP recovery across the loop boundary. Counts: 57 AWAKE, 35 DROWSY, 13 MICROSLEEP.

Local evidence: build/hardware_20261102_COM6_sequence/serial.log and summary.json. This validates the supplied observation sequence, not calibrated elapsed closure durations or electrical fault tolerance. Physical PC slots 10-15, SW13 hold, active-transaction reset and ownership handover remain separate checks.
