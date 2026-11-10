#!/usr/bin/env bash
# Evidence-only test: run a REAL source-built XNU kernel under a QEMU Cortex-A53
# and GICv2 machine. This is NOT an Exynos 7870 emulator and NOT a phone image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HAKIOS="$ROOT/hakios"
LOG="$ROOT/a53-evidence"
mkdir -p "$LOG"

if [[ ! -f "$HAKIOS/qemu/run.sh" ]]; then
  echo "FAIL: missing pinned HakiOS sources" >&2
  exit 2
fi
if [[ ! -s "$ROOT/imported-kernel/hakios/hakios-kernel" ]]; then
  echo "FAIL: missing real source-built kernel from archived build" >&2
  exit 3
fi

cp "$ROOT/imported-kernel/hakios/hakios-kernel" "$HAKIOS/hakios-kernel"
printf 'kernel_sha256=' > "$LOG/status.txt"
sha256sum "$HAKIOS/hakios-kernel" | awk '{print $1}' >> "$LOG/status.txt"
file "$HAKIOS/hakios-kernel" > "$LOG/kernel-file.txt"
grep -q 'Mach-O 64-bit arm64' "$LOG/kernel-file.txt" || {
  echo "FAIL: archive kernel is not ARM64 Mach-O" >&2
  exit 4
}
if [[ ! -s "$HAKIOS/prebuilt/userland/hello" || ! -s "$HAKIOS/prebuilt/loader.efi" ]]; then
  echo 'FAIL: pinned upstream kernel-free userland/loader evidence missing' >&2
  exit 5
fi

cd "$HAKIOS"
python3 xnuloader/mkpayload.py -o qemu/payload.bin \
  kernel=hakios-kernel ramdisk=prebuilt/userland/hello \
  --cmdline "cpus=1" --no-version > "$LOG/payload-build.log" 2>&1

# Isolated CI-only modification; the upstream file is never committed or flashed.
python3 - <<'PY'
from pathlib import Path
script = Path("qemu/run.sh")
s = script.read_text()
before = "-M virt,gic-version=3 -cpu cortex-a76"
after = "-M virt,gic-version=2 -cpu cortex-a53"
if s.count(before) != 1:
    raise SystemExit("FAIL: pinned QEMU invocation changed upstream")
script.write_text(s.replace(before, after))
PY

set +e
QEMU_MEM=4G bash qemu/run.sh 48 > "$LOG/qemu-cortex-a53-gicv2-serial.log" 2>&1
rc=$?
set -e
echo "qemu_process_exit=$rc" >> "$LOG/status.txt"
echo "machine=virt,gic-version=2" >> "$LOG/status.txt"
echo "cpu=cortex-a53" >> "$LOG/status.txt"

if grep -Fq '== XNULOADER v3 ==' "$LOG/qemu-cortex-a53-gicv2-serial.log"; then
  echo "loader_started=PASS" >> "$LOG/status.txt"
else
  echo "loader_started=FAIL" >> "$LOG/status.txt"
fi
if grep -Fq 'Darwin Kernel Version' "$LOG/qemu-cortex-a53-gicv2-serial.log"; then
  echo "xnu_started=PASS" >> "$LOG/status.txt"
else
  echo "xnu_started=FAIL" >> "$LOG/status.txt"
fi
if grep -Fq 'Hello from user space on Darwin!' "$LOG/qemu-cortex-a53-gicv2-serial.log"; then
  echo "hello_userland=PASS" >> "$LOG/status.txt"
else
  echo "hello_userland=FAIL" >> "$LOG/status.txt"
fi
echo "samsung_physical_boot=NOT_TESTED" >> "$LOG/status.txt"
echo "ios16_userland=NOT_TESTED" >> "$LOG/status.txt"
echo "installable_samsung_image=NO" >> "$LOG/status.txt"
cat "$LOG/status.txt"
grep -Fq 'xnu_started=PASS' "$LOG/status.txt"
grep -Fq 'hello_userland=PASS' "$LOG/status.txt"
