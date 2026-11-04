# Integration Decisions

## 2026-11-04: Live webcam host pipeline

- Reuse the team's MediaPipe FaceMesh/crop function with OpenCV grayscale and INTER_AREA resizing, followed by the established 576-byte CRC upload protocol.
- Use a Python 3.12 .venv-camera environment with a single OpenCV distribution; retain the existing UART environment.
- Keep one fixed eye per session and one persistent serial connection. Latest-frame replacement, a 250 ms age limit and paced single transactions avoid replay and growing queues.
- Target at most 10 inference observations per second initially. Log actual capture/send/result times; do not equate preview FPS or CNN latency with end-to-end throughput.
- Pause on missing/late observations, label display results stale, and require operator reset before resuming. UART errors stop without retry. The current protocol cannot reset/read back FPGA history automatically, and the physical alarm can persist after the host pauses.
- Keep images/video out of session logs by default. Provide a standalone Python preview rather than changing the existing file-oriented Windows GUI.

## 2026-11-03: External image input over UART

- Add a fixed 24x24 uint8 upload path while preserving ROM SLOT/RUN and board modes.
- Stage 576 bytes in synchronous-read RAM, validate CRC-16/CCITT-FALSE, then explicitly RUN_FRAME. Preserve the CNN loader's one-clock read contract, arithmetic and model exports.
- Use LOAD/RUN_FRAME with four-hex-digit IDs and decimal replies; identify results as source=UPLOAD with frame_id. Consume an uploaded frame once and reject immediate reuse of the last consumed ID.
- Reserve ownership during reception and output. Timeout/framing errors drain through a quiet interval before parser recovery. No automatic retries after uncertain execution.
- Do not interpret arbitrary uploads as elapsed closure time: temporal rules still count observations. Reset between sessions and record cadence for demonstrations.
- Retain final build and source-identified verification evidence; see integration/docs/IMAGE_UPLOAD_VERIFICATION.md. Physical acceptance remains pending.

## 2026-11-02: UART alignment with upstream fixed-point export

- Baseline: f9654aa971bc0ee45e52cd35baa335ecd28d85bd (PR 4 export and PR 5 RTL synchronization).
- Use the complete upstream export with S1=10 and S2=6. Preserve int8 weights and signed int32 logits. UART carries raw decimal integers, without dequantization or a protocol version change.
- Preserve CONF_MARGIN=1024 and existing temporal thresholds. Recalibration requires validation against the revised model. Slot 0 has margin 235 and is a directed SW13 hold test.
- New slot 0 is a different image. New slot 1 contains the old slot 0 image. Class IDs remain 0=CLOSED and 1=OPEN.
- Regenerate simulation data after updating exports. Reject missing or unknown vectors; do not accept a printed PASS alone.
- Keep implementation evidence for each build. Simulation scripts use unique build directories and do not erase previous bitstreams.
- The upstream exporter does not yet emit the nw*/na* metadata in params.txt. Treat the committed export as the numeric source of truth until its producer and fractional-bit rules are synchronized. Do not invent a dequantization scale.
