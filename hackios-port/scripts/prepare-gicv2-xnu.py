#!/usr/bin/env python3
"""Apply pinned HakiOS GICv2 + Cortex-A53 research changes (CI only).

Targets QEMU virt Cortex-A53/GICv2, not a Samsung boot image.
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
hakios = root / "hakios"
patch = hakios / "xnu/hakios.patch"
code = hakios / "xnu/files/osfmk/arm64/gic_v3_irq.c"
loader = hakios / "xnuloader/loader.c"
qemu = hakios / "qemu/run.sh"
new_driver = root / "hackios-port/experimental/gicv2-kernel.c"
assert all(p.is_file() for p in (patch, code, loader, qemu, new_driver))

s = patch.read_text()
old = "+#define GENERIC_GIC_V3_IRQ                 1"
if s.count(old) != 1:
    raise SystemExit("Pinned HakiOS GICv3 macro not found")
s = s.replace(old,
    old + "\n+#define GENERIC_GIC_V2_IRQ                 1 /* GICv2 ARMv8 research */")
oldpan = "+#define __ARM_PAN_AVAILABLE__     1"
if s.count(oldpan) != 1:
    raise SystemExit("Pinned HakiOS PAN macro not found")
s = s.replace(oldpan,
    "+#define __ARM_PAN_AVAILABLE__     0 /* ARMv8.0 Cortex-A53 */")
# The GNU diff hunk gains one line when adding the new GICv2 feature flag.
hunk = "@@ -11,6 +11,15 @@"
if s.count(hunk) != 1:
    raise SystemExit("Pinned BCM2837 header diff hunk changed")
s = s.replace(hunk, "@@ -11,6 +11,16 @@")
patch.write_text(s)

s = code.read_text()
oldif = "#if defined(GENERIC_GIC_V3_IRQ)"
oldend = "#endif /* GENERIC_GIC_V3_IRQ */"
if s.count(oldif) != 1 or s.count(oldend) != 1:
    raise SystemExit("Pinned GICv3 source markers changed")
s = s.replace(oldif,
    "#if defined(GENERIC_GIC_V3_IRQ) && !defined(GENERIC_GIC_V2_IRQ)")
s = s.replace(oldend,
    "#elif defined(GENERIC_GIC_V2_IRQ)\n" + new_driver.read_text()
    + "\n#endif /* GENERIC_GIC_V3_IRQ || GENERIC_GIC_V2_IRQ */")
code.write_text(s)

subprocess.run(["python3", str(root/"hackios-port/scripts/prepare-gicv2-loader.py")],
               check=True, cwd=root)
s = loader.read_text()
oldgicc = ".gic_dist = 0x08000000, .gic_redist = 0x080A0000"
if s.count(oldgicc) != 1:
    raise SystemExit("Pinned QEMU platform GIC address changed")
loader.write_text(s.replace(oldgicc,
    ".gic_dist = 0x08000000, .gic_redist = 0x08010000"))

s = qemu.read_text()
oldvirt = "-M virt,gic-version=3 -cpu cortex-a76"
if s.count(oldvirt) != 1:
    raise SystemExit("Pinned QEMU machine selection changed")
s = s.replace(oldvirt, "-M virt,gic-version=2 -cpu cortex-a53")
trace_key = "-display none -serial stdio -monitor none -no-reboot"
if s.count(trace_key) != 1:
    raise SystemExit("Pinned QEMU serial flags changed")
s = s.replace(trace_key,
    "-d int,guest_errors -D ../../ci-evidence/qemu-exceptions.log "
    + trace_key)
qemu.write_text(s)
print("GICV2_A53_XNU_AND_UEFI_PATCH=APPLIED")
print("PHYSICAL_SAMSUNG_BOOT=NOT_TESTED")
