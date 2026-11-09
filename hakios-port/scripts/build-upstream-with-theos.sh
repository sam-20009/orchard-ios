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
set +e
make qemu_defconfig > "$LOG/qemu-defconfig.log" 2>&1
DEF_RC=$?
printf 'qemu_defconfig_rc=%s\n' "$DEF_RC" | tee "$LOG/status.txt"
timeout 1100s make kernel JOBS=2 >"$LOG/real-xnu-kernel-build.log" 2>&1
KERNEL_RC=$?
printf 'make_kernel_rc=%s\n' "$KERNEL_RC" | tee -a "$LOG/status.txt"
if [ -s hakios-kernel ]; then
  file hakios-kernel | tee "$LOG/real-kernel-file.txt"
  sha256sum hakios-kernel | tee "$LOG/real-kernel-sha256.txt"
  timeout 180s make qemu-open SECS=35 JOBS=2 >"$LOG/make-qemu-open.log" 2>&1
  QEMU_RC=$?
  printf 'make_qemu_open_rc=%s\n' "$QEMU_RC" | tee -a "$LOG/status.txt"
else
  printf 'make_qemu_open_rc=NOT_TESTED(no compiled kernel)\n' | tee -a "$LOG/status.txt"
fi
tail -n 85 "$LOG/real-xnu-kernel-build.log"
test "$KERNEL_RC" -eq 0
