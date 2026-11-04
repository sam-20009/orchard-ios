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
IMAGE_SHA256 = "a8dbaecc8fdcd682991b078d6bbb7df6972e459208634fa8dcbad24f17208d6a"


def replace_once(path, old, new):
    original = path.read_text(encoding="utf-8")
    if original.count(old) != 1:
        raise ValueError(f"Expected one unmodified patch anchor in {path.name}")
    path.write_text(original.replace(old, new, 1), encoding="utf-8")



def normalize_stikjit_interfaces(source):
    """Spell the pinned Swift 6.4 interface's module selectors for Swift 6.2."""
    framework = source / (
        "src/app/Frameworks/StikJIT.xcframework/ios-arm64/StikJIT.framework"
    )
    module = framework / "Modules/StikJIT.swiftmodule"
    for name in ("arm64-apple-ios.swiftinterface", "arm64-apple-ios.private.swiftinterface"):
        path = module / name
        original = path.read_text(encoding="utf-8")
        if "Apple Swift version 6.4" not in original or "StikJIT::DDIPaths" not in original:
            raise ValueError(f"Unexpected StikJIT interface: {path.name}")

        # The module and its public enum have the same name. Use local names
        # for its top-level declarations and retain the enum's nested names.
        updated = original.replace("StikJIT::StikJIT.StikJIT::", "StikJIT.")
        updated = updated.replace("StikJIT::", "")
        for dependency in ("Swift", "Foundation", "_Concurrency"):
            updated = updated.replace(f"{dependency}::", f"{dependency}.")
        updated = updated.replace(" -interface-compiler-version 6.4", "")
        if "::" in updated:
            raise ValueError(f"Unhandled StikJIT module selector in {path.name}")
        path.write_text(updated, encoding="utf-8")


def apply_automatic_setup(app):
    content = app / "ContentView.swift"
    replace_once(content, "    @State private var started = false\n",
        '    @AppStorage("samuel.didStartAndroidSetup") private var didStartAndroidSetup = false\n'
        '    @State private var started = false\n')
    replace_once(content, "        try? guest.prepareFirmware()\n        guest.refresh()\n",
        '''        let firmwareReady = (try? guest.prepareFirmware()) != nil
        guest.refresh()
        // Remember the first attempt so foregrounding the app never overrides Cancel.
        if firmwareReady, !didStartAndroidSetup, guest.state == .missing {
            didStartAndroidSetup = true
            guest.download()
        }
''')

    image = app / "GuestImage.swift"
    replace_once(image, '    static let imageVersion = "v12"\n',
        f'    static let imageVersion = "v12"\n    static let imageSHA256 = "{IMAGE_SHA256}"\n')
    replace_once(image, r'        HuskLog.log("guest", "downloading guest image from \(Self.imageURL.absoluteString)")',
        r'''        let url = manifest?.imageURL ?? Self.imageURL
        let expectedDigest = manifest?.image.sha256 ?? Self.imageSHA256
        HuskLog.log("guest", "downloading guest image from \(url.absoluteString)")''')
    replace_once(image, "DownloadDelegate(owner: self)", "DownloadDelegate(owner: self, expectedDigest: expectedDigest)")
    replace_once(image, "session.downloadTask(with: manifest?.imageURL ?? Self.imageURL)", "session.downloadTask(with: url)")
    replace_once(image, "func finished(tempURL: URL, digest: String?)",
        "func finished(tempURL: URL, digest: String?, expectedDigest: String)")
    replace_once(image, "        if let want = manifest?.image.sha256, let got = digest, want != got {\n",
        '        if digest != expectedDigest {\n'
        '            let got = digest ?? "unavailable"\n'
        '            let want = expectedDigest\n')
    replace_once(image, "    init(owner: GuestImage) { self.owner = owner }",
        '''    let expectedDigest: String

    init(owner: GuestImage, expectedDigest: String) {
        self.owner = owner
        self.expectedDigest = expectedDigest
    }''')
    replace_once(image, "        Task { @MainActor in self.owner?.finished(tempURL: stable, digest: digest) }",
        '''        Task { @MainActor in
            self.owner?.finished(tempURL: stable, digest: digest, expectedDigest: self.expectedDigest)
        }''')
    replace_once(app / "ItemPages.swift",
        "Husk's Android runtime is about 760 MB. Android itself follows once it is installed.",
        "The Android system download is about 2.1 GB. Keep Samuel VR Box open while it downloads.")


def apply_overlay(source):
    app = source / "src/app/Husk"
    project = source / "src/app/project.yml"
    replace_once(project, "iOS: \"15.5\"", "iOS: \"26.0\"")
    replace_once(project, "HUSK_BUNDLE_IDENTIFIER: com.husk.app", "HUSK_BUNDLE_IDENTIFIER: com.samuel.vrbox")
    text = project.read_text(encoding="utf-8")
    project.write_text(text.replace('TARGETED_DEVICE_FAMILY: "1,2"', 'TARGETED_DEVICE_FAMILY: "1"'), encoding="utf-8")

    apply_automatic_setup(app)
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
    for overlay in sorted((KIT / "overlay").glob("VRBox*.swift")):
        shutil.copy2(overlay, app / overlay.name)

    # Keep build-setting placeholders used by Xcode (including extension IDs).
    info = app / "Info.plist"
    data = plistlib.loads(info.read_bytes())
    data.update(
        CFBundleDisplayName="Samuel VR Box",
        NSCameraUsageDescription="A câmera traseira rastreia a cabeça e a mão e mostra o ambiente quando você liga a visão da câmera.",
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
    normalize_stikjit_interfaces(options.husk_source)


if __name__ == "__main__":
    main()
