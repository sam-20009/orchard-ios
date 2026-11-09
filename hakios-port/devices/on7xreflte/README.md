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
