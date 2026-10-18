# Restoring the Original U-Boot Proxmox VE Environment

If you ever wish to revert your Firefly ITX-3588J from EDK2 UEFI back to the original Rockchip U-Boot setup on the eMMC (`/dev/mmcblk0`), complete backups and restoration scripts are provided.

---

## 1. Backed Up Assets
The original system state is preserved in `cache/`:
- **`cache/emmc-u-boot-header-16M.bin`**: Contains sectors 0 through 32767 (16 MiB) from `/dev/mmcblk0`, including:
  - Master Boot Record (MBR) and partition table
  - Rockchip SPL / `idbloader.img` at sector 64
  - U-Boot ITB image (`uboot.itb`) at sector 16384
- **`cache/pve-arm-firefly-rootfs.tar.zst`**: Full file-level archive of the working Proxmox VE ARM installation, including:
  - Original filesystem UUID: `5cb1c8d4-172b-4fb7-8c5a-52a601ad5fa0`
  - Vendor kernel, Device Tree, and U-Boot scripts (`armbianEnv.txt`, `boot.cmd`, `boot.scr`)
  - All Proxmox VE services, VM configurations, and user credentials

---

## 2. Automated Restoration

To restore the original U-Boot environment back onto the eMMC drive:

```bash
./scripts/restore-uboot-emmc.sh firefly /dev/mmcblk0
```

### What this script does:
1. Verifies that `/dev/mmcblk0` is not currently mounted as the active root filesystem.
2. Flashes the pristine 16 MiB U-Boot header back to `/dev/mmcblk0`.
3. Informs the Linux kernel of the restored partition table (`partprobe`).
4. Re-formats `/dev/mmcblk0p1` as ext4 using the original filesystem UUID (`5cb1c8d4-172b-4fb7-8c5a-52a601ad5fa0`).
5. Extracts `pve-arm-firefly-rootfs.tar.zst` with full file permissions, ACLs, and extended attributes.
6. Restores `armbianEnv.txt` to point `rootdev=UUID=5cb1c8d4-172b-4fb7-8c5a-52a601ad5fa0`.
7. Synchronizes disks and unmounts cleanly.

Upon reboot with SPI NOR bypassed or cleared, the board will boot into Proxmox VE ARM using U-Boot exactly as it did originally.
