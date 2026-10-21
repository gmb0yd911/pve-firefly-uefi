# Preserve the existing eMMC installation when adding UEFI boot

The Firefly was prepared in place on 2026-10-21. Its existing PVE root and
EDK2 firmware were retained. A whole-disk image was not written to eMMC.

## Current disk layout

| Area | Start sector | Size in sectors | Purpose |
| --- | ---: | ---: | --- |
| Existing root, p1 | 32768 | 483622912 | ext4 PVE root, unchanged boundaries and UUID |
| Existing firmware partition, p2 | 2048 | 16384 | Existing boot area, not formatted or moved |
| New EFI System Partition, p3 | 483655680 | 1048576 | 512 MiB FAT32, label PVE_EFI |

The firmware also occupies raw locations within the first 16 MiB; preserving
only the partition named `uboot` is insufficient. Firmware bytes from 64 KiB
through 16 MiB were hashed before and after partitioning and matched:
`56445abbb1a1218db5649fe1fa37c829bc094427865228d21542c3c32c1b1ab6`.
The first 64 KiB includes GPT metadata and was excluded from that comparison.

- Root UUID: `5cb1c8d4-172b-4fb7-8c5a-52a601ad5fa0`.
- ESP UUID: `49AE-B087`; mounted at `/boot/efi` by PVE.
- ESP PARTUUID: `ac94d4c4-0182-4d0c-af4f-1141f40ac581`.
- Firmware: existing EDK2 v1.1, Device Tree vendor mode, Force Output Disabled.

## Boot configuration

The new ESP contains systemd-boot 261.2, matched vendor 6.1.115 kernel and
PVE initrd, a board tree with the seven validated VOP clock holds, and:

- `proxmox.conf`: native HDMI with the patched device tree, default.
- `proxmox-headless.conf`: firmware device tree, SSH/serial recovery.

The PVE kernel is byte-identical to the kernel validated under Omarchy:
SHA256 `28369957f7ef770f80ba76f871175b784bb1fcbd8105b1c6644ea3f9ec80d108`.
Its original on-disk BSP tree matches the successful Omarchy input tree;
the generated eMMC tree therefore uses the same display-clock fix.

To boot, leave HDMI connected, reboot and choose the eMMC/PVE_EFI device
from the UEFI F12 boot menu. Its fallback file is
`\EFI\BOOT\BOOTAA64.EFI`. The PVE entry then starts automatically.
Keep the SATA Omarchy system available as recovery. Firmware settings and
boot order must be saved in UEFI setup: runtime EFI writes from Linux do
not persist with this eMMC-backed firmware implementation.

## Hardware validation result

The user selected eMMC in UEFI and confirmed a successful PVE boot with
HDMI connected on 2026-10-21. Independent SSH checks established:

- Boot ID: `8b33be60-7d25-442d-853f-b4771baf219c`.
- PVE 9.2.20, kernel `6.1.115-vendor-rk35xx`, UEFI active.
- Root mounted from `/dev/mmcblk0p1`, ESP from `/dev/mmcblk0p3`.
- LoaderDevicePartUUID matches the new eMMC ESP PARTUUID, confirming the
  EFI loader itself came from eMMC rather than SATA.
- HDMI-A-1 connected and all seven clock-hold regulators enabled.
- `vmbr0` up at `192.168.4.243/24`, default route via `192.168.4.1`.
- pve-cluster, pvedaemon, pveproxy, pvestatd and networking active.
- Web UI returns HTTP 200. The unauthenticated version API returns HTTP
  401 as expected; `pvesh` confirms the installed version and node online.
- Local directory storage active, with no configured VMs or containers.
- KVM API version 12; creating and closing an empty VM control instance
  succeeded. A guest OS has not been started as part of this validation.

The board's `rk3588-bluetooth.service` is the only failed unit and was left
unchanged. No PVE service is failed. SATA Omarchy remains installed and its
boot files were not modified by this migration.

Evidence is saved at `/root/pve-uefi-validation.json` on PVE and
`~/.local/state/firefly-pve-uefi/pve-hardware-validation.json` on the
workstation. This validates the in-place eMMC installation. The separately
rebuilt image passed content and compressed-integrity checks but has not
itself been flashed and booted on hardware.

## Management network

`configure-pve-network.sh` configures PVE's ifupdown2 bridge:

- `vmbr0` over `end0`, address `192.168.4.243/24`.
- Gateway `192.168.4.1`; DNS `9.9.9.9` and `1.1.1.1`.
- Web interface: `https://192.168.4.243:8006/`.
- SSH: `ssh -F ~/.ssh/config pve` (existing account and key).

The previous install enabled networkd/Netplan alongside ifupdown2. Networkd
and its wait-online service are now masked in the offline PVE root so they
cannot compete with the bridge. The management bridge parsed successfully
with PVE's installed `ifquery`. Original network files are retained under
`/var/backups/pve-uefi-network` in PVE.

## Backups and rollback

On the investigating workstation:

```text
~/.local/state/firefly-pve-uefi/emmc-uefi-header-before-pve-16M.bin
~/.local/state/firefly-pve-uefi/emmc-partitions-before-pve.sfdisk
```

On Omarchy's SATA root:

```text
/root/pve-uefi-migration-backup/emmc-before.sfdisk
/root/pve-uefi-migration-backup/pve-config-before.tar
```

To undo offline PVE configuration changes, boot Omarchy, mount the eMMC
root, remove the two newly created networkd mask symlinks if they point to
`/dev/null`, and extract `pve-config-before.tar` into that mounted root.
Unmount it before restoring partition metadata. The saved sfdisk layout
can restore the original partition table without rewriting the raw firmware.
The new ESP can also be retained unused; Omarchy's boot files are independent.

Kernel or initrd updates in PVE's ext4 `/boot` must be synchronized to the
separate ESP. Rebuild the patched DTB from a compatible vendor BSP tree when
changing the kernel/DTB pair. The seven clock consumers remain enabled;
suspend/resume and other display ports have not been validated.
