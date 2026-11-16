# Restoring the PVE image to eMMC without touching EDK2 (2026-11-15)

U-Boot testing overwrote the in-place eMMC PVE install described in
[the migration record](emmc-uefi-migration.md). EDK2 v1.1 was then
reflashed to the eMMC boot area. Afterwards the eMMC held only the 16 MiB
EDK2 image with its own GPT (p1 `uboot`, last LBA 32734). At sector 32768
there was a 128 MiB ext4 filesystem labelled `boot` from the U-Boot test,
and the old ESP was blank. The old PVE root could not be recovered.

PVE was restored from `output/proxmox-ve-arm-firefly-uefi.img.zst`
(built 2026-10-21). This was the first hardware boot of that image.
`deploy-uefi-image.sh` cannot be used because it writes the whole disk, and
`check-firmware-header.py` refuses that. The image reserves a blank 16 MiB
before its ESP, so only the image's partitions were written. This was done
from Fedora on the SATA SSD, with no eMMC partition mounted.

## Procedure

1. Back up the eMMC's first 16 MiB and its partition table to the
   workstation (`~/.local/state/firefly-pve-uefi/emmc-restore-20261115/`).
   Hash bytes 64 KiB to 16 MiB; the first 64 KiB holds the GPT.
2. Write a new GPT with `sfdisk --wipe never --wipe-partitions never`.
   The disk GUID and p1 are kept; p2 and p3 use the image's offsets and
   PARTUUIDs:

   | Partition | Start | Sectors | Name |
   | --- | ---: | ---: | --- |
   | p1 | 2048 | 16384 | `uboot` (kept, inside the EDK2 area) |
   | p2 | 32768 | 1048576 | `EFI` |
   | p3 | 1081344 | rest of disk | `pve_root` |

3. Stream the image from 16 MiB through the end of its root partition
   only:

   ```bash
   cat output/proxmox-ve-arm-firefly-uefi.img.zst | ssh <fedora> \
     'zstd -dc | sudo dd of=/dev/mmcblk0 bs=1M iflag=fullblock \
        skip=16 seek=16 count=12271 conv=fsync'
   ```

4. `fsck.vfat -n` on p2; `e2fsck -f` and `resize2fs` on p3.

## Verification

- The firmware bytes from 64 KiB to 16 MiB hashed
  `bdf1364344513cc2f4ad876a331d8c4d9e219fb8799b6ebd1ecec3d52d90410a` before
  and after both writes. `check-firmware-header.py` still detects EDK2.
- The 12,271 MiB written matched the image
  (`b4b8e27fdf94ca58a6a9feb7a1eeb87b13a2b1d48ee47cbd7ac9e6e3b2f1b2f8`).
- The first `e2fsck -f` reported `FILE SYSTEM WAS MODIFIED` without
  details. A read-only check after the resize was clean, and the root is
  229 GiB.
- The user chose eMMC from F12 and PVE booted the vendor kernel.

Identifiers of the restored install:

- Root UUID `4d72ea76-3f97-4865-b295-dd9054a1664e`, PARTUUID
  `df738c0f-d66a-4736-929c-35fe1d61656d`.
- ESP UUID `3FB9-86F8`, PARTUUID `94df60c2-935c-4536-8a1b-34b7177fd9e1`.

## First-boot problems

- **No network.** The image's `vmbr0` is a static `192.168.4.243` over
  `end0`. The cable was in the other port, so `end0` had no carrier.
  Moving the cable fixed it.
- **Clock 28 days behind.** The system clock started at the image's build
  time, although the hym8563 RTC was correct. Chrony had started without
  a network and had no sources. `systemctl restart chrony` stepped the
  clock; it was needed before `apt-get update`.

## ESP moved to `/boot/efi`

The image's `fstab` mounts the ESP at `/boot`, hiding the root
filesystem's own Armbian `/boot`. That `/boot` holds the vendor kernel,
initrd, `uInitrd` and DTBs. The mainline hooks expect the ESP at
`/boot/efi` and kernels in an ext4 `/boot`, as on the earlier install.
The `fstab` entry was changed to `/boot/efi`. The systemd-boot entries use
ESP-relative paths and did not change. The previous ESP contents and
`fstab` are in `/root/mainline-reapply-backup/` on PVE.

`build-uefi-image.sh` still writes the `/boot` mount. Images built from it
need the same change before the mainline kernel is installed.

## Mainline kernel reapplied

The setup in [mainline-kernel.md](mainline-kernel.md) was applied from the
running PVE. `firefly-mainline-cmdline` now carries the new root UUID.
`linux-image-7.2.9+deb13-arm64` is still in trixie-backports (7.2.11 and
7.2.12 are also available). After a reboot, the default entry selected
mainline 7.2.9. The checks were:

- system `running`, no failed units; PVE services active;
- `vmbr0` 192.168.4.243 over `end0`; `/dev/kvm` present;
- HDMI-A-1 connected;
- firewall enabled in nftables mode (`proxmox-firewall` 1.2.4). A
  5-minute rollback was armed. New SSH and the web UI (HTTP 200) worked,
  and ping was refused; the rollback was then cancelled.

Not working after a warm reboot from the vendor kernel: the AP6275P did
not respond. No device appeared on `0002:21`, and Bluetooth timed out
(`command 0xfc18 tx timeout`, `Reset failed (-110)`). Rebinding
`hci_uart_bcm` did not help. WL_REG_ON, BT_REG_ON and BT_WAKE were high,
`wifi_reg_on` was enabled and the hym8563 `lpo` clock was on.

A cold power cycle (power removed for about 10 s, then a mainline boot)
gave the same result. The system reached `running` and the firewall came
up, so the firewall persists across a reboot.

The module is dead. According to the user, it stopped working after a
crash during HDMI1 experiments in early November and also fails with
Firefly's stock firmware. Fedora's journal shows the same Bluetooth
timeout on every boot from 2026-11-01 onwards. The fuller record is in
fedora-firefly-uefi's `docs/bring-up.md`.

The AP6275P setup was therefore removed from PVE on 2026-11-16:

- `/usr/local/sbin/firefly-dt-ap6275p` was deleted, so
  `firefly-esp-mainline` copies Debian's DTB unchanged. The regenerated
  ESP DTB is identical to the package's, so `sata1` is back to stock and
  UART6 is disabled.
- `brcmfmac-after-bt.service` and `brcmfmac-after-bt.conf` were removed.
- The vendor `rk3588-bluetooth.service` was disabled.

This takes effect at the next boot. `bluez` stays installed.

On 2026-11-16 the Beryllium wiki's ITX-3588J Bluetooth fix
(<https://wiki.beryllium.gr/itx-3588j/Bluetooth-Fix>) was tested under the
vendor kernel. Its fix is to run `brcm_patchram_plus` on `/dev/ttyS6`
instead of `ttyS9`. Armbian's `rk3588-bluetooth.service` already does that,
with the same options and `BCM4362A2.hcd`. Its remaining step, an rfkill
block, 2 s wait and unblock, was done through `/sys/class/rfkill/rfkill0`
(`bt_default`). The `rfkill` tool is not installed. The vendor driver logged
the full sequence: power off, wake_host high, RTS toggled, power on.
`brcm_patchram_plus_rk3399 -d … --baudrate 1500000 --patchram
/lib/firmware/brcm/BCM4362A2.hcd /dev/ttyS6` then sent HCI Reset
(`01 03 0c 00`) repeatedly for 45 s, and 60 s in a run without the power
cycle. The chip never replied.
