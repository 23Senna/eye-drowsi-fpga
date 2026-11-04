# Current integrated build and host evidence — 2026-11-04

## FPGA build identity

- Source: 9dac15469da453cfe3ea5340ca7ef9e3e25fcf72 (PR #10 buzzer).
- Build: uart_hw_20261104_131740; top drowsiness_top, real filter-parallel CNN,
  UART/image upload and buzzer; part xc7a35tcpg236-1, 100 MHz.
- Raw report tool header: Vivado v2025.2, build 6299465. Earlier session notes
  call this installation 2025.2.1; the raw header is authoritative.
- Setup +0.948 ns, hold +0.067 ns; 2,376 LUT / 2,230 FF / 7.5 BRAM / 14 DSP.
- Bitstream SHA256: 4A21A9376E3E84E0A05CABC7B1123973D0A60FCB8569FCE91BF4E53EC00B86EB.
- Reproduction: vivado -mode batch -source integration/scripts/build_uart.tcl.
  Rebuilding can change placement and hashes.

source_sha256.json records 29 build inputs. All 29 matched byte-for-byte in
reviewed team main e3ac7ea during this documentation cleanup. This establishes
source equivalence, not a new implementation run or new device readback.
provenance.json is the original build-time record: its programmed=false
field describes that build session. Later user reports state the bitstream
was programmed and live GUI tested successfully. No new raw hardware sequence
or video was provided with that final GUI acceptance report.

Raw timing/utilization/DRC/clocks and original source hashes/provenance are
preserved unchanged. archive_manifest.json hashes these selected files.
The generated bitstream/project/checkpoints are intentionally excluded.
DRC warnings remain visible in drc.rpt; a timing pass does not mean zero warnings.

## Host evidence

host-tests.txt: 30 Python tests passed. smoke-result.txt: Release GUI bridge
smoke passed with a mock child backend; no camera/COM access in that test.
Source: f334995, merged by PR #11 into e3ac7ea. The GUI Release build reported
zero warnings/errors with .NET SDK 8.0.427. These selected logs are not a
new full physical/RTL acceptance run. Personal diagnostic crops are excluded.

## Historical measurements

The root reports one directory above describe the original failing RTL.
The [3 Nov archive](../uart_image_upload_20261103/README.md) describes the
serial-pipelined UART core (37,290 cycles), not this 7,996-cycle core.
Earlier team notes report a parallel UART build at 2,351 LUT / 2,181 FF,
setup +1.201 ns / hold +0.034 ns. It is a different build, without the same
archived input identity here; do not combine those numbers with this hash.
