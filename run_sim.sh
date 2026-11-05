#!/usr/bin/env bash
# Run every simulation in this repo with Icarus Verilog and check the results.
#   usage: ./run_sim.sh        (needs: iverilog, vvp, python3 + numpy)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
B="$ROOT/build/core_$(date +%Y%m%d_%H%M%S)_$$"; mkdir -p "$B"
PYTHON="${PYTHON:-python3}"
fail=0

echo "== [1/2] Top-level: tb_cnn vs ml/export/expected.txt (16 images, bit-exact logits)"
# rom_weights.v loads its .mem files by relative name, so run inside ml/export
iverilog -g2005 -o "$B/tb_cnn.vvp" \
  "$ROOT/rtl/cnn_top.v" \
  "$ROOT/rtl/rom_weights.v" \
  "$ROOT/rtl/conv1_layer.v" \
  "$ROOT/rtl/conv2_layer.v" \
  "$ROOT/rtl/fc_layer.v" \
  "$ROOT/rtl/mac_pipe.v" \
  "$ROOT/rtl/mac_pipe_lut.v" \
  "$ROOT/rtl/mac_sel.v" \
  "$ROOT/rtl/relu_requant.v" \
  "$ROOT/rtl/maxpool2x2.v" \
  "$ROOT/sim/tb_cnn.v"
( cd "$ROOT/ml/export" && vvp "$B/tb_cnn.vvp" ) > "$B/tb_cnn.log"
"$PYTHON" - "$B/tb_cnn.log" "$ROOT/ml/export/expected.txt" <<'EOP' || fail=1
import re, sys
got = {int(m[1]): (int(m[2]), int(m[3])) for l in open(sys.argv[1])
       if (m := re.search(r"Image\s+(\d+).*Logit0:\s*(-?\w+)\s*\|\s*Logit1:\s*(-?\w+)", l)) and "x" not in m[2] + m[3]}
exp = {}
for l in open(sys.argv[2]).read().splitlines()[1:]:
    sw, label, pred, l0, l1 = map(int, l.split()); exp[sw] = (l0, l1, label, pred)
bad = [i for i in exp if got.get(i) != exp[i][:2]]
ok = sum(1 for i in exp if got.get(i) is not None and (got[i][1] > got[i][0]) == (exp[i][2] == 1))
print(f"   logit mismatches vs golden: {len(bad)} / {len(exp)}   |  correct classifications: {ok} / {len(exp)}")
print("   PASS" if not bad and len(got) == len(exp) else f"   FAIL (images: {bad})")
sys.exit(1 if bad or len(got) != len(exp) else 0)
EOP

echo "== [2/2] Unit tests: relu_requant, conv_pe, conv+relu vs expected_a1/a2"
U="$B/unit"; mkdir -p "$U/mem"
cp "$ROOT"/ml/export/*.mem "$ROOT"/ml/export/params.txt "$U/mem/"
( cd "$U" && "$PYTHON" "$ROOT/sim/unit/gen_vectors.py" | sed 's/^/   /' )   # regenerates vectors + golden self-check
for tb in tb_relu_requant tb_conv_pe tb_conv_relu_golden; do
  iverilog -g2005 -Wall -o "$B/$tb.vvp" "$ROOT/rtl/conv_pe.v" "$ROOT/rtl/relu_requant.v" "$ROOT/sim/unit/$tb.v"
  out=$( cd "$U/mem" && vvp "$B/$tb.vvp" | grep -v '^VCD' )
  echo "$out" | grep -E "errors|PASSED|FAILED|mismatch" | sed 's/^/   /'
  echo "$out" | grep -q "TEST PASSED" || fail=1
  if echo "$out" | grep -Eq "ERROR:|FATAL:|TEST FAILED"; then fail=1; fi
done
[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
