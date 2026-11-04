#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" != Darwin ]; then
    echo "O IPA exige macOS com Xcode e o SDK do iPhone." >&2
    exit 1
fi
for tool in xcodebuild xcodegen qemu-img rustup cargo python3; do
    command -v "$tool" >/dev/null || { echo "Ferramenta ausente: $tool" >&2; exit 1; }
done
xcrun --sdk iphoneos --show-sdk-path >/dev/null

kit_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$kit_dir/dist"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
husk_commit=6e7f32572f19e7085686d5dd71ca58c02b725177
husk_checkout="$work_dir/husk"
ipa="$work_dir/Husk.ipa"

git init -q "$husk_checkout"
git -C "$husk_checkout" fetch --depth=1 https://github.com/Leviidev/Husk.git "$husk_commit"
git -C "$husk_checkout" checkout --quiet --detach FETCH_HEAD
test "$(git -C "$husk_checkout" rev-parse HEAD)" = "$husk_commit"
curl --fail --location --silent --show-error --retry 3 \
    https://github.com/Leviidev/Husk/releases/download/3.3/Husk.ipa -o "$ipa"
python3 "$kit_dir/tools/prepare_husk.py" "$husk_checkout" "$ipa"

cd "$husk_checkout"
lib_dir="$husk_checkout/build/ios-arm64/lib"
xcodebuild -create-xcframework \
    -framework "$lib_dir/release-frameworks/MoltenVK.framework" \
    -output "$lib_dir/MoltenVK.xcframework"
rustup target add aarch64-apple-ios
bash scripts/build_rppairing_ios.sh

export DD="$work_dir/derived"
bash scripts/package_ipa.sh "$kit_dir/dist/Samuel-VRBox.ipa"
python3 - "$kit_dir/dist/Samuel-VRBox.ipa" <<'PY'
import plistlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as ipa:
    root = "Payload/Husk.app/"
    info = plistlib.loads(ipa.read(root + "Info.plist"))
    assert info["CFBundleIdentifier"] == "com.samuel.vrbox", info["CFBundleIdentifier"]
    assert info["CFBundleShortVersionString"] == "3.3", info["CFBundleShortVersionString"]
    assert info["UIDeviceFamily"] == [1], info["UIDeviceFamily"]
    assert info["NSCameraUsageDescription"]
    assert any("samuelvrbox" in entry["CFBundleURLSchemes"] for entry in info["CFBundleURLTypes"])
    helper = plistlib.loads(ipa.read(root + "PlugIns/HuskJITHelper.appex/Info.plist"))
    assert helper["CFBundleIdentifier"] == info["CFBundleIdentifier"] + ".JITHelper"
    for resource in (
        "PlugIns/HuskJITHelper.appex/HuskJITHelper",
        "Frameworks/StikJIT.framework/StikJIT",
        "husk-jit.js",
        "java-runtime/husk-framework.dex",
        "java-runtime/com.android.art/lib64/libjavacore.so",
        "java-runtime/com.android.art/lib64/libopenjdk.so",
        "java-runtime/com.android.i18n/lib64/libicu_jni.so",
        "edk2-aarch64-code.fd",
        "lineage-efi-vars-seed.fd",
        "lineage-vdb-seed.qcow2",
        "vmlinuz-virt",
        "initramfs-virt",
        "Frameworks/libqemu-aarch64-softmmu.dylib",
        "Frameworks/libANGLE-shared.dylib",
    ):
        assert ipa.getinfo(root + resource).file_size > 0, resource
PY
