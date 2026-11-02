# Integration Decisions

## 2026-11-02: UART alignment with upstream fixed-point export

- Baseline: f9654aa971bc0ee45e52cd35baa335ecd28d85bd (PR 4 export and PR 5 RTL synchronization).
- Use the complete upstream export with S1=10 and S2=6. Preserve int8 weights and signed int32 logits. UART carries raw decimal integers, without dequantization or a protocol version change.
- Preserve CONF_MARGIN=1024 and existing temporal thresholds. Recalibration requires validation against the revised model. Slot 0 has margin 235 and is a directed SW13 hold test.
- New slot 0 is a different image. New slot 1 contains the old slot 0 image. Class IDs remain 0=CLOSED and 1=OPEN.
- Regenerate simulation data after updating exports. Reject missing or unknown vectors; do not accept a printed PASS alone.
- Keep implementation evidence for each build. Simulation scripts use unique build directories and do not erase previous bitstreams.
- The upstream exporter does not yet emit the nw*/na* metadata in params.txt. Treat the committed export as the numeric source of truth until its producer and fractional-bit rules are synchronized. Do not invent a dequantization scale.
