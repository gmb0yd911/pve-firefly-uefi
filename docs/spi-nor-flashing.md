# Firefly ITX-3588J: EDK2 UEFI SPI NOR Flashing & BIOS Guide

This guide describes how to flash the official **EDK2 UEFI firmware** to the SPI NOR flash on the **Firefly ITX-3588J** and configure the UEFI BIOS settings for Proxmox VE ARM.

---

## 1. Overview

By flashing EDK2 UEFI (`itx-3588j_UEFI_Release_v1.1.img` from `edk2-porting/edk2-rk3588`) to the onboard SPI NOR flash:
1. The board will boot via standard UEFI on power-on.
2. The UEFI BIOS menu (`ESC` / `F2`) and boot selection menu (`F12`) become accessible.
3. You can boot any connected storage device (eMMC, SATA SSD, NVMe, USB) using standard EFI System Partitions (ESP) without needing U-Boot.

---

## 2. Flashing Methods

### Method 1: USB Type-C OTG in MaskRom Mode (Recommended)
This is the standard, foolproof Rockchip hardware recovery and flashing method:

1. **Prerequisites**:
   - Install Rockchip tools on your Arch Linux host:
     ```bash
     sudo pacman -S rkdeveloptool
     # or build from source if not in repo: yay -S rkdeveloptool
     ```
   - Connect a USB Type-C cable between your PC and the **Type-C OTG port** on the Firefly ITX-3588J.

2. **Enter MaskRom Mode**:
   - Disconnect power from the Firefly board.
   - Press and hold the **BOOT / MASKROM button** on the ITX-3588J motherboard.
   - Connect power to the board while holding the button.
   - Wait 3 seconds, then release the button.

3. **Verify Device Detection**:
   ```bash
   rkdeveloptool ld
   # Output should indicate: DevNo=1  Vid=0x2207,Pid=0x350b,LocationID=... Maskrom
   ```

4. **Flash EDK2 UEFI to SPI NOR**:
   ```bash
   # Initialize DDR memory using Rockchip SPL loader:
   rkdeveloptool db cache/rk3588_spl_loader.bin

   # Write the EDK2 image to SPI flash:
   rkdeveloptool wl 0 cache/itx-3588j_UEFI_Release_v1.1.img

   # Reboot the board:
   rkdeveloptool rd
   ```

---

### Method 2: In-Linux Flashing (via MTD device)
If your running Linux kernel has the Serial Flash Controller (SFC) enabled:

1. Check for the MTD device:
   ```bash
   cat /proc/mtd
   ```
2. Flash using `flashcp` or `dd`:
   ```bash
   sudo flashcp cache/itx-3588j_UEFI_Release_v1.1.img /dev/mtd0
   # or
   sudo dd if=cache/itx-3588j_UEFI_Release_v1.1.img of=/dev/mtdblock0 bs=4k status=progress conv=fsync
   ```

---

### Method 3: eMMC Software UEFI (Alternative if SPI NOR is unpopulated)
If you wish to use EDK2 UEFI without touching SPI NOR, you can flash EDK2 directly to the eMMC bootloader sector (`/dev/mmcblk0`):
```bash
./scripts/flash-spi-nor-edk2.sh firefly /dev/mmcblk0
```

---

## 3. Required EDK2 UEFI BIOS Setup

When booting into EDK2 UEFI for the first time:

1. Connect an HDMI display to **HDMI Output 1** (top port) and connect a USB keyboard.
2. Power on the Firefly board.
3. Tap **ESC** or **F2** repeatedly as soon as power is applied to enter the **EDK2 Setup Utility**.
4. Navigate using arrow keys to:
   ```
   Device Manager  -->  Rockchip Platform Configuration
   ```
5. Set **Config Table Mode** to **Device Tree (FDT)**:
   > [!IMPORTANT]
   > Do **NOT** leave this on ACPI. The Linux 6.1 vendor kernel and hardware components (Mali GPU, VOP2 HDMI, PCIe, SATA, USB3, and NPU) require the Rockchip Device Tree Blob (`rk3588-firefly-itx-3588j.dtb`). ACPI mode will cause devices to fail to initialize.
6. Press **F10** to save changes.
7. Press **ESC** to exit and reboot.

---

## 4. Boot Order Selection
- Press **F12** during boot to bring up the UEFI Boot Menu.
- Select your target drive (`Proxmox VE ARM 9` / `systemd-boot`).
- EDK2 will automatically remember this choice as the default boot entry.
