#!/usr/bin/env bash
# Build upstream HakiOS from real original XNU using real Theos cctools and SDK.
# GitHub Actions Ubuntu runner only. No phone, firmware, image-flash operations.
set -uo pipefail
TOP="$(pwd)"
mkdir -p ci-evidence
LOG="$TOP/ci-evidence"
export THEOS="$TOP/theos"
mkdir -p "$THEOS/toolchain" "$THEOS/sdks"
echo "UPSTREAM=$(git -C hakios rev-parse HEAD)" | tee "$LOG/provenance.txt"
echo '== Clone Theos and real SDK ==' | tee "$LOG/theos-setup.log"
git clone --depth 1 https://github.com/theos/theos.git "$THEOS" >>"$LOG/theos-setup.log" 2>&1
# Toolchain is third-party, installed only inside ephemeral CI; no system mutation.
curl -fLsS --retry 2 --connect-timeout 20 \
  https://github.com/L1ghtmann/llvm-project/releases/latest/download/iOSToolchain-x86_64.tar.xz \
  -o "$LOG/iOSToolchain-x86_64.tar.xz" >>"$LOG/theos-setup.log" 2>&1
CURL_RC=$?
if [ "$CURL_RC" -ne 0 ]; then
  echo "TOOLCHAIN_DOWNLOAD_FAIL exit=$CURL_RC" | tee -a "$LOG/theos-setup.log"
  exit "$CURL_RC"
fi
tar -xJf "$LOG/iOSToolchain-x86_64.tar.xz" -C "$THEOS/toolchain" >>"$LOG/theos-setup.log" 2>&1
TAR_RC=$?
rm -f "$LOG/iOSToolchain-x86_64.tar.xz"
if [ "$TAR_RC" -ne 0 ]; then echo "TOOLCHAIN_UNPACK_FAIL" | tee -a "$LOG/theos-setup.log"; exit "$TAR_RC"; fi
if [ ! -x "$THEOS/toolchain/linux/iphone/bin/ld" ]; then
  echo 'NO_REAL_CCTOOLS_LINKER: installer did not provide ld' | tee -a "$LOG/theos-setup.log"
  exit 23
fi
"$THEOS/toolchain/linux/iphone/bin/ld" -v >> "$LOG/theos-setup.log" 2>&1 || true
git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git "$TOP/theos-sdks" >>"$LOG/theos-setup.log" 2>&1
git -C "$TOP/theos-sdks" sparse-checkout set iPhoneOS16.5.sdk >>"$LOG/theos-setup.log" 2>&1
ln -s "$TOP/theos-sdks/iPhoneOS16.5.sdk" "$THEOS/sdks/iPhoneOS16.5.sdk"
test -d "$THEOS/sdks/iPhoneOS16.5.sdk/usr/include" || { echo "SDK_MISSING" | tee -a "$LOG/theos-setup.log"; exit 24; }
echo "THEOS_REAL_SDK_AND_LINKER_READY" | tee -a "$LOG/theos-setup.log"
cd hakios || exit 1
TARGET="${HAKIOS_TARGET:-qemu}"
case "$TARGET" in
  qemu) ;;
  on7xreflte)
    cp -a "$TOP/hakios-port/devices/on7xreflte" "$TOP/hakios/devices/" || exit 27
    ;;
  *) echo "UNSUPPORTED_TARGET=$TARGET" | tee "$LOG/status.txt"; exit 28 ;;
esac
printf 'target=%s\n' "$TARGET" | tee "$LOG/status.txt"
if [ "$TARGET" = "on7xreflte" ]; then
  python3 tools/hakios-device.py check "$TARGET" > "$LOG/device-check.log" 2>&1
  CHECK_RC=$?
  printf 'device_check_rc=%s\n' "$CHECK_RC" | tee -a "$LOG/status.txt"
  if [ "$CHECK_RC" -ne 0 ]; then tail -n 90 "$LOG/device-check.log"; exit "$CHECK_RC"; fi
fi
make "${TARGET}_defconfig" > "$LOG/device-defconfig.log" 2>&1
DEF_RC=$?
printf 'device_defconfig_rc=%s\n' "$DEF_RC" | tee -a "$LOG/status.txt"
if [ "$DEF_RC" -ne 0 ]; then tail -n 90 "$LOG/device-defconfig.log"; exit "$DEF_RC"; fi
make config > "$LOG/device-config.log" 2>&1
CONFIG_RC=$?
printf 'device_config_rc=%s\n' "$CONFIG_RC" | tee -a "$LOG/status.txt"
if [ "$CONFIG_RC" -ne 0 ]; then tail -n 90 "$LOG/device-config.log"; exit "$CONFIG_RC"; fi
cp -f .config "$LOG/active-config.txt"
timeout 1100s make kernel JOBS=2 >"$LOG/real-xnu-kernel-build.log" 2>&1
KERNEL_RC=$?
printf 'make_kernel_rc=%s\n' "$KERNEL_RC" | tee -a "$LOG/status.txt"
if [ -f xnu-deps/exporthdrs.log ]; then
  cp -f xnu-deps/exporthdrs.log "$LOG/exporthdrs.log"
  echo '=== EXACT EXPORT_HDRS ERRORS ==='
  grep -nEi 'error:|fatal|not found|no such file|make: \*\*\*' "$LOG/exporthdrs.log" | head -n 45 || true
  tail -n 65 "$LOG/exporthdrs.log" || true
fi
if [ -s hakios-kernel ]; then
  file hakios-kernel | tee "$LOG/real-kernel-file.txt"
  sha256sum hakios-kernel | tee "$LOG/real-kernel-sha256.txt"
  if [ "$TARGET" = "qemu" ]; then
    timeout 180s make qemu-open SECS=35 JOBS=2 >"$LOG/make-qemu-open.log" 2>&1
    QEMU_RC=$?
    printf 'make_qemu_open_rc=%s\n' "$QEMU_RC" | tee -a "$LOG/status.txt"
    if [ -f logs/qemu-open.log ]; then
      if grep -Fq '== XNULOADER v3 ==' logs/qemu-open.log &&
         grep -Fq 'Darwin Kernel Version' logs/qemu-open.log; then
        echo 'qemu_xnu_boot=PASS' | tee -a "$LOG/status.txt"
      else
        echo 'qemu_xnu_boot=FAIL(no boot evidence)' | tee -a "$LOG/status.txt"
        exit 31
      fi
    else
      echo 'qemu_xnu_boot=FAIL(no serial log)' | tee -a "$LOG/status.txt"
      exit 32
    fi
  else
    printf 'make_qemu_open_rc=NOT_TESTED(Exynos config cannot be validated in QEMU virt)\n' | tee -a "$LOG/status.txt"
    printf 'samsung_hardware_boot=NOT_TESTED\n' | tee -a "$LOG/status.txt"
  fi
else
  echo 'kernel_artifact=FAIL(no compiled kernel)' | tee -a "$LOG/status.txt"
  exit 33
fi
tail -n 85 "$LOG/real-xnu-kernel-build.log"
test "$KERNEL_RC" -eq 0
