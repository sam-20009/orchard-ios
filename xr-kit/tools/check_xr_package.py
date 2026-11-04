#!/usr/bin/env python3
"""Inspeciona APKs Android para a primeira triagem de compatibilidade XR."""

import argparse
from collections import Counter
import lzma
import re
import shutil
import struct
import tempfile
from pathlib import Path, PurePosixPath
import zipfile
import zlib


MIB = 1024 * 1024
MAX_SPLIT_BYTES = 768 * MIB
MAX_BUNDLE_BYTES = 1280 * MIB
MAX_NATIVE_BYTES = 1024 * MIB
MAX_LIBRARY_BYTES = 512 * MIB
MAX_LITERAL_BYTES = 256 * MIB
MAX_SPLITS = 64
CHUNK = MIB

ELF_HEADER = struct.Struct("<16sHHIQQQIHHHHHH")
PROGRAM_HEADER = struct.Struct("<IIQQQQQQ")
DYNAMIC_ENTRY = struct.Struct("<qQ")
LIBRARY_NAME = re.compile(rb"[A-Za-z0-9_.+\-]{1,200}")
ANDROID_DEPENDENCIES = {
    "libandroid.so", "libnativewindow.so", "libjnigraphics.so", "liblog.so",
    "libmediandk.so", "libaaudio.so", "libbinder_ndk.so", "libOpenSLES.so",
    "libc.so", "libc++_shared.so", "libdl.so", "libm.so", "libz.so",
}
XR_MARKERS = (
    b"libopenxr_loader.so", b"libopenxr_runtime.so", b"xrGetInstanceProcAddr",
    b"xrInitializeLoaderKHR", b"xrCreateInstance", b"XR_KHR_android_create_instance",
    b"XR_KHR_loader_init_android", b"XR_KHR_opengl_es_enable", b"XR_KHR_vulkan_enable",
    b"XR_KHR_vulkan_enable2", b"XR_EXT_hand_tracking",
)
GRAPHICS_MARKERS = (b"libEGL.so", b"libGLESv3.so", b"libGLESv2.so", b"libvulkan.so")
QUEST_MARKERS = (b"libvrapi.so", b"libovrplatformloader.so", b"com.oculus.vr.focusaware")
MARKERS = XR_MARKERS + GRAPHICS_MARKERS + QUEST_MARKERS
MARKER_OVERLAP = max(map(len, MARKERS)) - 1
ARCHIVE_ERRORS = (OSError, EOFError, ValueError, RuntimeError, zipfile.BadZipFile, zlib.error, lzma.LZMAError)


def read_at(file, offset, length, file_size):
    if offset < 0 or length < 0 or offset + length > file_size:
        raise ValueError("estrutura ELF fora do arquivo")
    file.seek(offset)
    data = file.read(length)
    if len(data) != length:
        raise ValueError("estrutura ELF truncada")
    return data


def elf_dependencies(file, file_size):
    """Lê DT_NEEDED a partir dos segmentos ELF, inclusive em binários stripped."""
    header = ELF_HEADER.unpack(read_at(file, 0, ELF_HEADER.size, file_size))
    ident, elf_type, machine, version = header[:4]
    if ident[:7] != b"\x7fELF\x02\x01\x01" or machine != 183 or elf_type != 3 or version != 1:
        raise ValueError("não é uma biblioteca ELF64 AArch64 little-endian")
    ph_offset, ph_size, ph_count = header[5], header[9], header[10]
    if ph_size != PROGRAM_HEADER.size or not 1 <= ph_count <= 1024:
        raise ValueError("tabela de segmentos ELF inválida")
    segments = list(PROGRAM_HEADER.iter_unpack(read_at(file, ph_offset, ph_size * ph_count, file_size)))
    dynamic = next((segment for segment in segments if segment[0] == 2), None)
    if dynamic is None:
        return set()

    dyn_offset, dyn_size = dynamic[2], dynamic[5]
    if dyn_size > MIB or dyn_size % DYNAMIC_ENTRY.size:
        raise ValueError("tabela dinâmica ELF inválida")
    string_address = string_size = None
    needed_offsets = []
    for tag, value in DYNAMIC_ENTRY.iter_unpack(read_at(file, dyn_offset, dyn_size, file_size)):
        if tag == 0:
            break
        if tag == 1:
            needed_offsets.append(value)
        elif tag == 5:
            string_address = value
        elif tag == 10:
            string_size = value

    if not needed_offsets:
        return set()
    if string_address is None or string_size is None or not 0 < string_size <= 32 * MIB:
        raise ValueError("tabela de nomes das dependências ELF inválida")
    for segment_type, _, offset, address, _, size, _, _ in segments:
        if segment_type == 1 and address <= string_address and string_address + string_size <= address + size:
            names = read_at(file, offset + string_address - address, string_size, file_size)
            break
    else:
        raise ValueError("tabela de nomes ELF não mapeada em PT_LOAD")

    dependencies = set()
    for offset in needed_offsets:
        end = names.find(b"\0", offset, offset + 201)
        if end != -1 and LIBRARY_NAME.fullmatch(names[offset:end]):
            dependencies.add(names[offset:end].decode("ascii"))
    return dependencies


def literal_markers(file, size, limit):
    pending = set(MARKERS)
    found = set()
    tail = b""
    remaining = min(size, limit)
    while remaining and pending:
        chunk = file.read(min(CHUNK, remaining))
        if not chunk:
            break
        data = tail + chunk
        matched = {marker for marker in pending if marker in data}
        pending.difference_update(matched)
        found.update(matched)
        tail = data[-MARKER_OVERLAP:]
        remaining -= len(chunk)
    return found


def grouped_signals(library, dependencies, markers):
    xr = {name for name in dependencies if name.lower().startswith("libopenxr")}
    packaged_loader = (
        {library}
        if library.lower().startswith("libopenxr")
        and LIBRARY_NAME.fullmatch(library.encode("ascii", "backslashreplace"))
        else set()
    )
    graphics = {
        name for name in dependencies
        if name.lower().startswith(("libegl.", "libgles", "libvulkan."))
    }
    quest_names = {marker.decode("ascii") for marker in QUEST_MARKERS}
    return [
        ("Biblioteca OpenXR empacotada", packaged_loader),
        ("OpenXR em DT_NEEDED", xr),
        ("OpenXR em literais", {m.decode("ascii") for m in markers.intersection(XR_MARKERS)} - xr),
        ("EGL/GLES/Vulkan", graphics | {m.decode("ascii") for m in markers.intersection(GRAPHICS_MARKERS)}),
        ("Quest/VrApi", (dependencies & quest_names) | {m.decode("ascii") for m in markers.intersection(QUEST_MARKERS)}),
    ]


def inspect_apk(archive, label, budget):
    entries = archive.infolist()
    counts = Counter(entry.filename for entry in entries)
    if counts["AndroidManifest.xml"] != 1:
        print(f"  Ignorado {label!r}. O APK precisa ter um único AndroidManifest.xml na raiz.")
        return False

    print(f"APK {label!r}")
    architectures = set()
    libraries = []
    for entry in entries:
        path = entry.filename.split("/")
        if len(path) != 3 or path[0] != "lib" or not path[2].endswith(".so"):
            continue
        architectures.add(path[1])
        if path[1] == "arm64-v8a":
            libraries.append(entry)
    print("  ABIs declaradas em lib/: " + (", ".join(repr(abi) for abi in sorted(architectures)) or "nenhuma"))

    confirmed = 0
    android_dependencies = set()
    xr_detected = False
    partial_literals = False
    for entry in libraries:
        if counts[entry.filename] != 1:
            print(f"  Ignorado {entry.filename!r}: nome duplicado.")
            continue
        if entry.file_size > MAX_LIBRARY_BYTES or entry.file_size > budget["native"]:
            print(f"  Ignorado {entry.filename!r}: limite de inspeção de binários.")
            continue

        budget["native"] -= entry.file_size
        scan_size = min(entry.file_size, budget["literals"])
        partial_literals |= scan_size < entry.file_size
        try:
            with archive.open(entry) as binary:
                dependencies = elf_dependencies(binary, entry.file_size)
        except ARCHIVE_ERRORS as error:
            print(f"  Ignorado {entry.filename!r}: {str(error)!r}.")
            continue
        confirmed += 1
        android_dependencies.update(dependencies & ANDROID_DEPENDENCIES)
        markers = set()
        if scan_size:
            budget["literals"] -= scan_size
            try:
                with archive.open(entry) as binary:
                    markers = literal_markers(binary, entry.file_size, scan_size)
            except ARCHIVE_ERRORS as error:
                print(f"  Literais indisponíveis em {entry.filename!r}: {str(error)!r}.")
                partial_literals = True
        groups = grouped_signals(PurePosixPath(entry.filename).name, dependencies, markers)
        xr_detected |= any(bool(values) for _, values in groups[:3])
        if any(values for _, values in groups):
            print(f"  {entry.filename!r}")
            for title, values in groups:
                if values:
                    print(f"    {title}: {', '.join(sorted(values))}")

    print(f"  Bibliotecas ELF64 AArch64 confirmadas: {confirmed}")
    if android_dependencies:
        print("  Dependências Android/bionic: " + ", ".join(sorted(android_dependencies)))
    print("  OpenXR em ARM64: " + ("há indícios" if xr_detected else "nenhum indício detectado"))
    if partial_literals:
        print("  A busca por literais foi parcial devido ao limite de leitura ou a um erro.")
    return True


def inspect_bundle(archive, budget):
    entries = archive.infolist()
    counts = Counter(entry.filename for entry in entries)
    splits = [entry for entry in entries if entry.filename.lower().endswith(".apk") and not entry.is_dir()]
    print("Pacote de APKs. Cada membro é analisado separadamente, pois o pacote pode conter variantes.")
    inspected = 0
    remaining = MAX_BUNDLE_BYTES
    if len(splits) > MAX_SPLITS:
        print(f"  O pacote contém {len(splits)} APKs; serão inspecionados no máximo {MAX_SPLITS}.")
    for entry in splits[:MAX_SPLITS]:
        path = PurePosixPath(entry.filename)
        if (counts[entry.filename] != 1 or path.as_posix() != entry.filename
                or path.is_absolute() or ".." in path.parts or "\\" in entry.filename):
            print(f"  Ignorado {entry.filename!r}: caminho ambíguo.")
            continue
        if entry.file_size > MAX_SPLIT_BYTES or entry.file_size > remaining:
            print(f"  Ignorado {entry.filename!r}: limite de leitura de APKs no pacote.")
            continue
        remaining -= entry.file_size
        try:
            with tempfile.SpooledTemporaryFile(max_size=8 * MIB) as storage:
                with archive.open(entry) as split:
                    shutil.copyfileobj(split, storage, CHUNK)
                storage.seek(0)
                with zipfile.ZipFile(storage) as apk:
                    inspected += inspect_apk(apk, entry.filename, budget)
        except ARCHIVE_ERRORS as error:
            print(f"  Ignorado {entry.filename!r}: {str(error)!r}.")
    return inspected > 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path, help="arquivo .apk, .apks ou .xapk já disponível no dispositivo")
    args = parser.parse_args()
    extension = args.package.suffix.lower()
    if extension not in {".apk", ".apks", ".xapk"}:
        parser.error("use um arquivo .apk, .apks ou .xapk")

    budget = {"native": MAX_NATIVE_BYTES, "literals": MAX_LITERAL_BYTES}
    try:
        with zipfile.ZipFile(args.package) as archive:
            valid = (
                inspect_apk(archive, args.package.name, budget)
                if extension == ".apk" else inspect_bundle(archive, budget)
            )
    except ARCHIVE_ERRORS as error:
        parser.exit(2, f"Erro ao abrir o pacote: {str(error)!r}.\n")
    if not valid:
        parser.exit(2, "Nenhum APK com um AndroidManifest.xml na raiz foi encontrado.\n")

    print("Resultado estático. Bibliotecas ARM64 e indícios OpenXR não confirmam que o jogo inicia.")
    print("No iPhone, o teste de VR exige um runtime Android/OpenXR local e a renderização de dois olhos.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
