# Debian mainline kernel on the eMMC PVE install

Since 2026-10-23 the eMMC PVE install boots Debian's backports kernel
`7.2.9+deb13-arm64` by default, with the vendor `6.1.115-vendor-rk35xx`
entry kept as a fallback. The mainline kernel uses its own in-tree board
device tree, so the VOP clock-hold tree used by the vendor entry is not
needed: rockchip-drm takes over HDMI from EDK2 without a panic.

The same 7.2 kernel series and device tree were first validated on this
board by [fedora-firefly-uefi](https://github.com/gmb0yd911/fedora-firefly-uefi)
(Fedora 7.2.11).

## Boot entries

| Entry | Kernel | Device tree | Role |
| --- | --- | --- | --- |
| `proxmox-mainline.conf` | `/mainline/vmlinuz-7.2.9+deb13-arm64` | `/mainline/rockchip/rk3588-firefly-itx-3588j.dtb` (Debian's) | default |
| `proxmox.conf` | vendor 6.1.115 | `/dtb/rockchip/…` (clock-hold tree) | fallback |
| `proxmox-headless.conf` | vendor 6.1.115 | firmware tree | recovery |

systemd-boot shows the menu for 5 seconds. To boot the vendor kernel, pick
**Proxmox VE ARM (eMMC UEFI HDMI)**. To make it the default again:

```bash
sudo sed -i 's/^default .*/default proxmox.conf/' /boot/efi/loader/loader.conf
```

The mainline entry passes `panic=10`. A kernel that panics therefore
reboots into the default entry again; choose the vendor entry from the menu.

## Installation

The kernel was installed from Fedora on the SATA disk, in a native aarch64
chroot of the eMMC root (`/dev/mmcblk0p1` with the ESP at `/boot/efi`). It
can equally be installed from a running PVE:

```bash
sudo apt-get install --no-install-recommends \
  linux-image-7.2.9+deb13-arm64 linux-base/trixie-backports
```

Only `linux-base` is taken from backports explicitly. `-t trixie-backports`
would also upgrade unrelated packages such as `linux-libc-dev`. Kernel
headers are deliberately not installed, so the `zfs-dkms` hook skips the
build: no ZFS pool exists, and ZFS 2.4.4 has not been checked against 7.2.

Files from `config/mainline-kernel/` in this repository are installed as:

| Repository file | Installed as |
| --- | --- |
| `firefly-esp-mainline` | `/usr/local/sbin/firefly-esp-mainline` |
| `kernel-hook` | `/etc/kernel/postinst.d/zz-firefly-esp-mainline` and `/etc/kernel/postrm.d/zz-firefly-esp-mainline` |
| `initramfs-post-update` | `/etc/initramfs/post-update.d/firefly-esp-mainline` |
| `initramfs-hook-firefly-edid` | `/etc/initramfs-tools/hooks/firefly-edid` |
| `firefly-mainline-cmdline` | `/etc/kernel/firefly-mainline-cmdline` |
| `dell_p2720dc-240mhz.bin` | `/usr/lib/firmware/edid/dell_p2720dc-240mhz.bin` |
| `systemd/rk3588-bluetooth.service.d/vendor-kernel-only.conf` | `/etc/systemd/system/rk3588-bluetooth.service.d/` |
| `systemd/pve-firewall.service.d/ebtables-nft.conf` | `/etc/systemd/system/pve-firewall.service.d/` |

The vendor `ttyFIQ0` getty was moved from `getty.target.wants/` to
`/etc/systemd/system/dev-ttyFIQ0.device.wants/`:

```bash
sudo mkdir -p /etc/systemd/system/dev-ttyFIQ0.device.wants
sudo mv /etc/systemd/system/getty.target.wants/serial-getty@ttyFIQ0.service \
  /etc/systemd/system/dev-ttyFIQ0.device.wants/
```

Every change also applies under the vendor kernel. There the getty starts
when the FIQ debugger device appears, and the Bluetooth service still runs.

## Keeping the ESP current

The ESP holds copies of the kernel, initramfs and DTB. `firefly-esp-mainline`
runs after every kernel install or removal and every `update-initramfs`, and:

- copies the newest installed non-vendor kernel, its initramfs and DTB to
  `/boot/efi/mainline/`, only when they changed, and deletes older copies;
- rewrites `proxmox-mainline.conf` with the options in
  `/etc/kernel/firefly-mainline-cmdline` (edit that file, not the entry);
- puts `/boot/uInitrd` back on the vendor initramfs, because Armbian's
  `99-uboot` hook repoints it at whichever initramfs was built last, which
  would break the [U-Boot fallback](recovery-and-uboot-fallback.md);
- if no mainline kernel remains, removes the entry and makes `proxmox.conf`
  the default again.

Only that exact kernel version is installed; there is no meta-package, so
`apt upgrade` does not move to a newer kernel. To change kernels, install
the new `linux-image-<version>-arm64` from backports (the hook switches the
entry to it), boot it, then remove the old one.

## Kernel options

`/etc/kernel/firefly-mainline-cmdline` keeps the vendor entry's options and
adds `drm.edid_firmware=HDMI-A-1:edid/dell_p2720dc-240mhz.bin
video=HDMI-A-1:2560x1440`. The DDC EDID read fails on this board. The
240 MHz EDID avoids the fractional HDPTX PLL rate that produces red
sparkles at the monitor's native 241.5 MHz; see the Fedora project's README.

## Validation (2026-10-23)

Booted the mainline entry from the systemd-boot menu:

- `systemctl is-system-running`: `running` (after the `ttyFIQ0` and
  Bluetooth changes), no failed units.
- `pve-cluster`, `pvedaemon`, `pveproxy`, `pvestatd` active; pve-manager 9.2.20.
- `vmbr0` 192.168.4.243 over `end0`. On mainline, `end0` is also
  `fe1b0000.ethernet`, the port with the cable, so `interfaces` is unchanged.
- `/dev/kvm` present; a `qemu-system-aarch64 -accel kvm -cpu host` guest
  booted a kernel.
- HDMI-A-1 2560x1440, `tmds_char_rate=240000000`; Panthor, rockchipdrm,
  ahci_dwc loaded.

After it was made the default, the hook was exercised with
`update-initramfs -u`: the ESP initramfs matched `/boot` and `uInitrd` was
restored to the vendor file. A following unattended boot selected
`proxmox-mainline.conf` (`LoaderEntrySelected`) and reached `running` with
the same services, `vmbr0`, `/dev/kvm` and 240 MHz HDMI.

## Firewall (nftables mode)

The legacy firewall cannot run on this kernel. `pve-firewall.service` forces
`ebtables-legacy` (`ExecStartPre=update-alternatives --set ebtables
…-legacy`), and Debian's 7.2 config does not set
`CONFIG_BRIDGE_NF_EBTABLES_LEGACY`. Since 2026-10-23 the firewall therefore
runs on the nftables-based `proxmox-firewall`:

```bash
sudo apt-get install --no-install-recommends proxmox-firewall   # 1.2.3, pulls nftables
printf '[OPTIONS]\n\nnftables: 1\n' | sudo tee /etc/pve/nodes/pve/host.fw
sudo pvesh set /cluster/firewall/options --enable 1
```

In nftables mode, pve-firewall still applies an empty ebtables ruleset
every 10 s to clean up legacy chains. With the legacy backend that logged
`Module ebtables not found` each time. The `ebtables-nft.conf` drop-in
replaces the unit's `ExecStartPre` list. It keeps the `iptables`/`ip6tables`
legacy settings and points only `ebtables` at nft. After it was installed,
pve-firewall logged no errors.

The datacenter firewall was enabled with a 5-minute `systemd-run` rollback
armed (`pvesh set /cluster/firewall/options --enable 0`). The rollback was
cancelled after these checks from 192.168.4.222:

- a new SSH connection succeeded;
- `https://192.168.4.243:8006/` returned 200;
- ping is refused: PVE's default input policy drops all traffic except
  management access (`v4-dc/management`, detected as `192.168.4.0/24`).

The ruleset is `table inet proxmox-firewall`. `pve-firewall status` shows
`enabled/running (pending changes)`. That status reflects the legacy
iptables ruleset, which nftables mode does not apply.

After a reboot with the firewall enabled, the system reached `running`.
`proxmox-firewall` loaded its table, pve-firewall logged no errors, and
SSH and the web UI were reachable while ping was refused. Not tested yet:
the vendor kernel in nftables mode, and guest (bridge) rules.

If access is lost, disable it at the console: `pvesh set
/cluster/firewall/options --enable 0`. Alternatively, set `enable: 0` in
`/etc/pve/firewall/cluster.fw`.

## Not available under mainline

- **ZFS** (no module; see above).
- **Bluetooth/Wi-Fi**: the mainline DT has no UART6 or Bluetooth node.
- **NPU and vendor video decoding** (rkmpp).
- **Stable Ethernet MAC**: the mainline DT supplies none, so the MAC is
  random on every boot. The static address on `vmbr0` is not affected.

## Backups

Taken from Fedora before the first write, in `~/pve-mainline-backup/` on
the Fedora SATA disk, with `SHA256SUMS`:

- `pve-esp-before.tar`: the whole ESP.
- `pve-boot-dpkg-before.tar`: PVE `/boot`, `var/lib/dpkg/status`,
  `etc/network/interfaces`.

Armbian's `xx-initramfs-cleanup` hook deleted the unused
`/boot/uInitrd-7.1-mainline` from the earlier 7.1 experiment; it is in the
second tarball.
