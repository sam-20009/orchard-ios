#!/usr/bin/env python3
"""Patch pinned HakiOS UEFI loader to feature-gate GICv3 and PAN instructions.

Build-only research for QEMU Cortex-A53/GICv2. Does not produce a firmware image.
The original loader unconditionally reads ICC_PMR_EL1 and faults under GICv2.
"""
from pathlib import Path

path = Path("hakios/xnuloader/loader.c")
s = path.read_text(encoding="utf-8")
lines = s.splitlines(keepends=True)

def insert_before(needle: str, asm: list[str]) -> None:
    matches = [i for i, line in enumerate(lines) if needle in line]
    if len(matches) != 1:
        raise SystemExit(f"Expected one {needle!r}, found {len(matches)}")
    i = matches[0]
    lines[i:i] = [f'        "{ins}\\n"\n' for ins in asm]

def insert_after(needle: str, asm: list[str]) -> None:
    matches = [i for i, line in enumerate(lines) if needle in line]
    if len(matches) != 1:
        raise SystemExit(f"Expected one {needle!r}, found {len(matches)}")
    i = matches[0] + 1
    lines[i:i] = [f'        "{ins}\\n"\n' for ins in asm]

# ID_AA64PFR0_EL1 [27:24] GIC: architectural ICC_* system registers.
# This test must be checked against actual QEMU model behavior.
guard = ["  mrs x11, id_aa64pfr0_el1", "  ubfx x11, x11, #24, #4"]
insert_before("mrs x9, icc_pmr_el1", guard + ["  cbz x11, 9f"])
insert_after("mrs x9, icc_bpr1_el1", ["9:"])
insert_before("msr icc_pmr_el1, x9", guard + ["  cbz x11, 8f"])
insert_after("msr icc_igrpen1_el1, x9", ["8:"])

# ID_AA64MMFR1_EL1 [23:20] PAN: ARMv8.0/A53 has no PSTATE.PAN
# or UAO. Avoid an undefined instruction when returning to firmware.
# Two return stubs each have PAN/UAO instructions. Guard both,
# using local numeric labels, without touching the original caller state.
pan = [i for i, line in enumerate(lines) if ".inst 0xd500409f" in line]
uao = [i for i, line in enumerate(lines) if ".inst 0xd500407f" in line]
if len(pan) != 2 or len(uao) != 2:
    raise SystemExit("Unexpected PAN/UAO return-stub layout")
for idx, (p, u) in reversed(list(enumerate(zip(pan, uao)))):
    if u != p + 1:
        raise SystemExit("PAN/UAO pair no longer adjacent")
    label = "7" if idx == 0 else "6"
    lines.insert(u + 1, f'        "{label}:\\n"\\n')
    for ins in reversed([
        "  mrs x11, id_aa64mmfr1_el1",
        "  ubfx x11, x11, #20, #4",
        f"  cbz x11, {label}f",
    ]):
        lines.insert(p, f'        "{ins}\\n"\\n')

out = "".join(lines)
assert out.count("  cbz x11, 9f") == 1
assert out.count("  cbz x11, 8f") == 1
assert out.count("  cbz x11, 7f") == 1
assert out.count("  cbz x11, 6f") == 1
path.write_text(out, encoding="utf-8")
print("LOADER_FEATURE_GUARDS_APPLIED=YES")
