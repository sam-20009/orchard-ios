#!/usr/bin/env bash
# Cortex-A53 (ARMv8.0) XNU build: do not emit PSTATE.PAN operations.
# Upstream HakiOS enables PAN unconditionally because its target is A55/A76.
# The Exynos7870's Cortex-A53 does NOT implement PAN (introduced by ARMv8.1).
# This replaces one build-time macro in a pinned source patch, not a firmware.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCH="$ROOT/hakios/xnu/hakios.patch"
QEMU="$ROOT/hakios/qemu/run.sh"
test -f "$PATCH" && test -f "$QEMU"

python3 - "$PATCH" "$QEMU" <<'PY'
from pathlib import Path
import sys
patch, qemu = map(Path, sys.argv[1:])
src = patch.read_text()
old = "+#define __ARM_PAN_AVAILABLE__     1"
new = "+#define __ARM_PAN_AVAILABLE__     0 /* ARMv8.0 Cortex-A53 has no PAN */"
if src.count(old) != 1:
    raise SystemExit("PAN patch not at expected pinned upstream revision")
patch.write_text(src.replace(old, new))
qsrc = qemu.read_text()
before = "-M virt,gic-version=3 -cpu cortex-a76"
after = "-M virt,gic-version=3 -cpu cortex-a53"
if qsrc.count(before) != 1:
    raise SystemExit("QEMU CPU selection not at expected pinned upstream revision")
qemu.write_text(qsrc.replace(before, after))
print("CORTEX_A53_NO_PAN_PATCH=APPLIED")
print("QEMU_CPU=cortex-a53")
print("QEMU_GIC=3 (only for isolating CPU compatibility, NOT Exynos GICv2)")
PY
