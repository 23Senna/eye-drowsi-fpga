# UART image-upload evidence, 3 November 2026

Small reviewable artifacts are committed here; generated Vivado projects,
checkpoints, virtual environments and bitstreams stay outside source control.
archive_manifest.json maps each copied file to its original local build path
and SHA256. Files preserve original bytes, including line endings.

- `implementation/operator_tested_build/`: original image-upload reports,
  exact build-input hashes and bitstream hash. Operator tests followed the
  instructions to program this build; terminal output alone does not verify
  the programmed bitstream identity.
- `implementation/integrated_build/`: fresh implementation after integrating
  main 56c0237. It has separate provenance from the operator-tested build.
- `simulation/`: original 23-check consolidated evidence, original Icarus
  source manifests and xsim logs, post-integration targeted checks/xsim logs,
  and 16 host test results. These are multiple runs, not one all-case run.
- `hardware/first/`, `new_images/`, `closed_sequence/`, `recovery/`: operator
  terminal observations and validated summaries. Some initial captures are
  normalized from user-supplied chat text; recovery preserves the attachment.
- `hardware/crc/`, `timeout/`, `reset/`: operator-run checker logs and summaries.
  Each records rejection, no RESULT in the checked quiet interval and a fresh
  valid recovery upload. Reset timing is manually confirmed, not pin-probed.
- `hardware/demo/`: two 24x24 PNG crops from committed ml/test.npz and their
  integer-model expectations. Each pixel array is absent from all 16 ROM
  images. Source indices and image SHA256 are in expected.json.

Reproduction commands and limits are documented in
[IMAGE_UPLOAD.md](../../../integration/docs/IMAGE_UPLOAD.md) and
[IMAGE_UPLOAD_VERIFICATION.md](../../../integration/docs/IMAGE_UPLOAD_VERIFICATION.md).
Use source=UPLOAD and frame_id for external-image results; slot=0 is a
compatibility field. Timing telemetry excludes upload and serial output.

The evidence covers educational frame-count behavior. It does not establish
camera accuracy, calibrated closure durations, exhaustive electrical fault
tolerance, or independently read-back bitstream identity.
