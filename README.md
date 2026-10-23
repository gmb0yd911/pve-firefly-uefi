# Proxmox VE ARM for Firefly ITX-3588J (EDK2 UEFI)

This repository contains the complete toolkit, backups, and built images for running **Proxmox VE ARM 9** under the **EDK2 UEFI BIOS** (`edk2-rk3588`) on the **Firefly ITX-3588J** (Rockchip RK3588).

The existing eMMC installation now boots through UEFI with HDMI connected.
SSH, web UI, PVE services, local storage and KVM control-instance creation
were verified on hardware. Its root and firmware were preserved; see the
[migration and validation record](docs/emmc-uefi-migration.md).

It now boots Debian's mainline `7.2.9+deb13-arm64` kernel with its in-tree
device tree by default; the vendor 6.1 entry remains as a fallback. See
[docs/mainline-kernel.md](docs/mainline-kernel.md) for the setup, the ESP
sync hook and what is unavailable under mainline (notably pve-firewall).

---

## 1. Project Overview

Previously, the Proxmox VE ARM system installed on the internal eMMC drive (`/dev/mmcblk0`) booted via proprietary Rockchip U-Boot scripts (`armbianEnv.txt` / `boot.scr`) relying on raw sector offsets.

This project delivers:
1. **Full Backup of the Working U-Boot Environment**:
   - `cache/emmc-u-boot-header-16M.bin`: First 16 MiB of the eMMC drive (MBR + U-Boot SPL & ITB).
   - `cache/pve-arm-firefly-rootfs.tar.zst`: Complete file-level backup of the Proxmox VE ARM rootfs (1.3 GiB).
   - `scripts/restore-uboot-emmc.sh`: Automated restoration script to revert to U-Boot anytime.
2. **UEFI Bootable Image (`proxmox-ve-arm-firefly-uefi.img.zst`)**:
   - Standard GPT partition table with 512 MiB FAT32 EFI System Partition (ESP) + ext4 root partition.
   - Built with native `systemd-boot` (`BOOTAA64.EFI`) loading the vendor Linux 6.1 kernel via ARM64 EFI Stub (`CONFIG_EFI_STUB=y`).
   - Firefly BSP device tree with the native HDMI UEFI handoff clock fix.
   - Matching vendor kernel/initrd, headless recovery entry, and PVE management bridge.
   - Drive-agnostic `UUID` boot parameters (can boot from eMMC, SATA SSD, NVMe M.2 SSD, or USB).
3. **Firmware & Deployment Scripts**:
   - `scripts/deploy-uefi-image.sh`: Flashes the UEFI image to any drive and automatically expands it to fill physical disk capacity.
   - `scripts/flash-spi-nor-edk2.sh`: Flashes official EDK2 UEFI BIOS to SPI NOR.

---

## 2. Directory Structure

```
├── cache/
│   ├── emmc-u-boot-header-16M.bin      # Original eMMC U-Boot SPL + ITB (16 MiB)
│   ├── itx-3588j_UEFI_Release_v1.1.img # Official EDK2 UEFI firmware image (6.6 MiB)
│   ├── pve-arm-firefly-rootfs.tar.zst  # Pristine Proxmox VE ARM rootfs backup (1.3 GiB)
│   ├── rk3588-firefly-itx-3588j.dtb    # Hardware Device Tree Blob (272 KiB)
│   └── systemd-bootaa64.efi            # ARM64 UEFI systemd-boot binary (168 KiB)
├── config/
│   └── mainline-kernel/                # ESP sync hook, kernel options, EDID, systemd drop-in
├── docs/
│   ├── mainline-kernel.md              # Debian mainline kernel default entry and its limits
│   ├── pve-uefi-architecture.md        # Technical architecture comparison (U-Boot vs UEFI)
│   ├── spi-nor-flashing.md             # Guide to flashing EDK2 UEFI to SPI NOR
│   └── recovery-and-uboot-fallback.md  # Step-by-step restoration to legacy U-Boot
├── output/
│   ├── proxmox-ve-arm-firefly-uefi.img     # 12 GiB sparse UEFI GPT disk image
│   └── proxmox-ve-arm-firefly-uefi.img.zst # 1.3 GiB compressed UEFI disk image
└── scripts/
    ├── build-uefi-image.sh             # Build the UEFI GPT disk image from rootfs
    ├── deploy-uefi-image.sh            # Stream & deploy image over SSH to target disk
    ├── flash-spi-nor-edk2.sh           # Flash EDK2 firmware to SPI NOR
    └── restore-uboot-emmc.sh           # Restore original U-Boot eMMC state
```

---

## 3. Quick Start Guide

### Step 1: Flash EDK2 UEFI to SPI NOR
To enable UEFI booting on the hardware, flash the official EDK2 firmware to SPI NOR.
See [docs/spi-nor-flashing.md](file:///home/gmb0yd911/Work/pve-firefly-uefi/docs/spi-nor-flashing.md) for full instructions:
```bash
./scripts/flash-spi-nor-edk2.sh firefly
```

### Step 2: Configure UEFI BIOS Settings
1. Connect an HDMI display to **HDMI Output 1** (top port) and connect a USB keyboard.
2. Power on the Firefly board and press **ESC** or **F2** to enter UEFI Setup.
3. Navigate to:
   ```
   Device Manager  -->  Rockchip Platform Configuration
   ```
4. Set **Config Table Mode** to **Device Tree (FDT)**.
5. Press **F10** to save, then **ESC** to exit and reboot.

### Step 3: Deploy the UEFI Proxmox VE Image
**The current eMMC also contains UEFI firmware. Do not write a whole-disk
image over it.** Its existing PVE root has been retained and a new ESP added
in trailing free space. Follow the [in-place migration record](docs/emmc-uefi-migration.md)
for its layout, backups and boot validation.

The whole-image deployer refuses a target containing a recognized EDK2 FIT
image. Whole-disk deployment is only suitable for a target whose firmware
is already supplied by separately validated storage, for example a secondary
SSD. Booting Omarchy from SATA does not itself establish that eMMC is safe
to overwrite.

For a separate OS disk:
```bash
# Flash to a secondary SSD with separately provided UEFI firmware:
./scripts/deploy-uefi-image.sh firefly /dev/nvme0n1
```
The deploy script will:
1. Stream the compressed image to the target drive.
2. Fix the secondary GPT header at the end of the disk.
3. Automatically expand the root partition and ext4 filesystem to fill 100% of the drive.

### Step 4: Access Proxmox VE
Once booted under UEFI:
- **Web Console**: `https://192.168.4.243:8006/`
- **SSH**: `ssh gmb0yd911@192.168.4.243` or `ssh root@192.168.4.243`

### Rebuilding the updated image

```bash
./scripts/build-uefi-image.sh
```

The builder uses vendor `6.1.115-vendor-rk35xx` and its matching initrd,
generates display clock holds, starts the ESP after a 16 MiB reserved gap,
and configures `vmbr0`. Management defaults can be overridden with
`PVE_ADDRESS`, `PVE_GATEWAY`, and `PVE_INTERFACE`. The gap is blank in the
image; it does not preserve target firmware during a whole-disk write.

The original compressed image is retained as
`output/proxmox-ve-arm-firefly-uefi.before-clock-fix.img.zst`.

## Related

- [fedora-firefly-uefi](https://github.com/gmb0yd911/fedora-firefly-uefi): Fedora Cinnamon with a Btrfs root, booting on the SATA SSD through the
  same EDK2 UEFI firmware with Fedora's mainline kernel and device tree.
