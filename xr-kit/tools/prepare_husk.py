#!/usr/bin/env python3
"""Apply the iPhone profile to the pinned Husk checkout and stage release dependencies."""
import argparse
import bz2
import hashlib
import plistlib
import shutil
import zipfile
from pathlib import Path

KIT = Path(__file__).resolve().parents[1]
RELEASE_SHA256 = "5c39d7dc2d90d75c2df03900cda7f240271a90b7d89fff504df7fa4da49e9d3f"


def replace_once(path, old, new):
    original = path.read_text(encoding="utf-8")
    if original.count(old) != 1:
        raise ValueError(f"Expected one unmodified patch anchor in {path.name}")
    path.write_text(original.replace(old, new, 1), encoding="utf-8")


def apply_overlay(source):
    app = source / "src/app/Husk"
    project = source / "src/app/project.yml"
    replace_once(project, "iOS: \"15.5\"", "iOS: \"26.0\"")
    replace_once(project, "HUSK_BUNDLE_IDENTIFIER: com.husk.app", "HUSK_BUNDLE_IDENTIFIER: com.samuel.vrbox")
    text = project.read_text(encoding="utf-8")
    project.write_text(text.replace('TARGETED_DEVICE_FAMILY: "1,2"', 'TARGETED_DEVICE_FAMILY: "1"'), encoding="utf-8")

    replace_once(app / "ContentView.swift", "                SettingsTab()\n",
        '''                VRBoxLabTab()
                    .tabItem { Label("VR Box", systemImage: "eyeglasses") }
                    .tag(HuskTab.vrbox)

                SettingsTab()
''')
    routers = list(app.rglob("*.swift"))
    declarations = [path for path in routers if "enum HuskTab:" in path.read_text(encoding="utf-8")]
    if len(declarations) != 1:
        raise ValueError("Cannot locate unique HuskTab enum")
    enum_file = declarations[0]
    text = enum_file.read_text(encoding="utf-8")
    enum_decl = next(line for line in text.splitlines() if "enum HuskTab:" in line)
    replace_once(enum_file, enum_decl, enum_decl + "\n    case vrbox")

    # Keep the upstream first-run file picker and helper. Enable its existing
    # auto-enable path by default, after the user completes pairing and VPN setup.
    replace_once(app / "HuskApp.swift", "        let d = UserDefaults.standard\n",
        '        let d = UserDefaults.standard\n'
        '        d.register(defaults: ["husk.jit.autoEnable": true, "husk.downloadSnapshot": false])\n')
    shutil.copy2(KIT / "overlay/VRBoxLab.swift", app / "VRBoxLab.swift")

    # Keep build-setting placeholders used by Xcode (including extension IDs).
    info = app / "Info.plist"
    data = plistlib.loads(info.read_bytes())
    data.update(
        CFBundleDisplayName="Samuel VR Box",
        NSCameraUsageDescription="A câmera traseira rastreia a cabeça e a mão para controlar a bancada VR.",
    )
    info.write_bytes(plistlib.dumps(data, sort_keys=False))


def sha256_file(path):
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def seed_release(source, ipa):
    if sha256_file(ipa) != RELEASE_SHA256:
        raise ValueError("Husk 3.2.1 IPA does not match the pinned SHA-256")
    with zipfile.ZipFile(ipa) as archive:
        prefix = "Payload/Husk.app/"
        names = archive.namelist()

        def copy_file(relative, destination, *, compress=False):
            destination.parent.mkdir(parents=True, exist_ok=True)
            opener = bz2.open if compress else open
            with archive.open(prefix + relative) as payload, opener(destination, "wb") as out:
                shutil.copyfileobj(payload, out)

        def copy_tree(relative, destination):
            key = prefix + relative + "/"
            files = [name for name in names if name.startswith(key) and not name.endswith("/")]
            if not files:
                raise ValueError(f"Missing dependency directory {relative}")
            for name in files:
                suffix = Path(name[len(key):])
                if suffix.is_absolute() or ".." in suffix.parts:
                    raise ValueError(f"Invalid dependency path in {relative}")
                copy_file(name[len(prefix):], destination / suffix)

        lib = source / "build/ios-arm64/lib"
        for name in ("libqemu-aarch64-softmmu.dylib", "libhuskps4.dylib"):
            copy_file(f"Frameworks/{name}", lib / name)
        copy_file("Frameworks/libANGLE-shared.dylib",
            source / "build/ios-arm64/sysroot/lib/libANGLE-shared.dylib")
        copy_tree("Frameworks/MoltenVK.framework", lib / "release-frameworks/MoltenVK.framework")
        for name in ("vmlinuz-virt", "initramfs-virt"):
            copy_file(name, source / "guests/phase0" / name)
        bios = source / "third_party/build/qemu-10.0.12-utm/pc-bios"
        copy_tree("pc-bios", bios)
        copy_file("edk2-aarch64-code.fd", bios / "edk2-aarch64-code.fd.bz2", compress=True)
        for resource in ("android-system", "java-runtime"):
            copy_tree(resource, source / "build" / resource)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("husk_source", type=Path)
    parser.add_argument("husk_release_ipa", type=Path)
    options = parser.parse_args()
    seed_release(options.husk_source, options.husk_release_ipa)
    apply_overlay(options.husk_source)


if __name__ == "__main__":
    main()
