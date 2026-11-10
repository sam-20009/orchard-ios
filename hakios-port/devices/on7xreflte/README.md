# Experimental HakiOS Exynos7870 port — on7xreflte

Target Samsung Galaxy J7 Prime 2 **SM-G611MT** (not on7xelte).
The existing U-Boot build and experimental DT remain on the parent branch
under `hackios-g611mt/` and are not proof of S-Boot compatibility.

## Initial memory observations
Reference: on7xreflte Samsung vendor DTS collected during prior HackiOS work.

- DRAM bank 0: 0x40000000 length 0x3d800000
- DRAM bank 1: 0x80000000 length 0x80000000
- Vendor UART candidates: 0x13810000, 0x13800000, 0x13820000
- SoC: Exynos 7870; ARMv8 Cortex-A53, GICv2; 26 MHz oscillator
- Storage: eMMC/DW-MMC; not the Qualcomm UFS driver
- Display: Samsung DECON/DSI (physical framebuffer not verified)
- Touch: Synaptics RMI4; no XNU HID integration

These are **research observations**, not safe physical load addresses or
verified runtime settings. RAM reservations, MMU entry state, secure monitor,
EL transitions and bootargs still need dedicated work.

No Qualcomm addresses, SPMI, UFS, Adreno, or ABL fastboot boot path should be
carried over to the Samsung. No code here performs flashing.

## Requirements before physical test
Prove S-Boot compatible image format, verify boot and recovery path with broken
Home button independent of Android, and obtain separate explicit approval.


## 2026-11-10 — S-Boot and XNU machine-level readiness

**What passes:** the HakiOS Exynos-specific configuration is accepted, and a
Mach-O arm64 XNU binary is built in CI. This does NOT make the kernel
compatible with the SM-G611MT.

**What still blocks real boot:**

- The XNU source build uses `MACHINE_CONFIGS=BCM2837`, not a validated
  Exynos7870 machine bootstrap. The Exynos device configuration alone
  does not change the kernel's ARM platform entry, interrupt controller,
  timer, early console, MMU and SoC-specific support.
- The Samsung S-Boot -> compatible U-Boot / UEFI -> xnuloader handoff has
  not been demonstrated on this precise model.
- No device-verified boot image, recovery procedure or physical serial
  trace has been recorded. The phone's Home key is damaged.
- The HakiOS research kernel does not incorporate a complete, proven
  iOS 16 userland for this Samsung.
- The source file `hackios-g611mt/sboot-exynos7870-bootinfo.dts` is a
  host-only device-tree information stub following the upstream U-Boot
  Exynos 7870 discovery structure. It contains zero-sized memory
  placeholders that S-Boot normally populates at run time. It is NOT
  a firmware image or a tested physical device-tree replacement.

**Evidence labels:**
`XNU_ARM64_COMPILE=PASS`;
`XNU_EXYNOS_BOOT=NOT_TESTED`;
`IOS16_USERLAND=NOT_IMPLEMENTED`;
`INSTALLABLE_ROM=NO`.

Upstream U-Boot documentation:
https://docs.u-boot.org/en/latest/board/samsung/exynos-mobile/exynos7870.html

No Samsung firmware, storage or partition is written by the CI tasks.
