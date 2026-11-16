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
chroot of the eMMC root (`/dev/mmcblk0p1` with the ESP at `/boot/efi`).
After the 2026-11-15 restore it was reinstalled from the running PVE
(root on `/dev/mmcblk0p3`, ESP moved to `/boot/efi`; see
[the restore record](emmc-image-restore.md)):

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
| `firefly-dt-ap6275p` | `/usr/local/sbin/firefly-dt-ap6275p` (not installed since 2026-11-16) |
| `brcmfmac-after-bt.conf` | `/etc/modprobe.d/brcmfmac-after-bt.conf` (not installed since 2026-11-16) |
| `brcmfmac-after-bt.service` | `/etc/systemd/system/`, enabled (wanted by `sys-subsystem-bluetooth-devices-hci0.device`); not installed since 2026-11-16 |

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
  `/boot/efi/mainline/`, only when they changed, and deletes older copies.
  The DTB is passed through `firefly-dt-ap6275p` first (see
  [Wi-Fi and Bluetooth](#wi-fi-and-bluetooth-ap6275p));
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

## Wi-Fi and Bluetooth (AP6275P)

**Not in use; the module is dead.** Since 2026-11-16 the files in this
section are not installed on PVE: no `firefly-dt-ap6275p`, no
`brcmfmac-after-bt` files, and `rk3588-bluetooth.service` disabled.
`firefly-esp-mainline` then copies Debian's DTB unchanged. See
[the restore record](emmc-image-restore.md). The description below is
kept for a replacement module.

The board's AP6275P module is a BCM43752: Wi-Fi on `pcie2x1l0`
(`/pcie@fe170000`), Bluetooth on UART6 (`/serial@feb90000`). The mainline
DT describes neither, and also enables `sata1` (`/sata@fe220000`), which
shares combo PHY 1 with `pcie2x1l0`. The built-in AHCI driver takes the PHY
first, so the Wi-Fi link never trains (`Device not found`). The vendor DT
disables `sata1`, and nothing is connected to it.

`firefly-dt-ap6275p IN OUT` adds the wiring from the vendor DT. It works
by node path, because Debian's DTBs have no `__symbols__` and leave out
unreferenced pin groups. It:

- disables `sata1`;
- adds a `regulator-fixed` on GPIO0_C4 (WL_REG_ON) as the slot's
  `vpcie3v3-supply`;
- enables UART6 with the m1 RTS/CTS pins, adding the missing
  `uart6m1-ctsn`/`-rtsn` groups;
- adds a `brcm,bcm4345c5` serdev node with BT_REG_ON (GPIO0_C6) as
  `shutdown-gpios`, BT_WAKE (GPIO0_C5) and the hym8563 32 kHz output as
  its `lpo` clock.

The Wi-Fi firmware fails to start (`FW failed to initialize`) unless that
LPO is already running, and `hci_uart_bcm` is what enables it. So
`brcmfmac` is blacklisted for automatic loading, and
`brcmfmac-after-bt.service` loads it once `hci0` exists.

Packages and firmware:

- `bluez` was installed (Armbian's `5.82-1.1+rpt2`, the candidate from the
  configured repositories).
- Firmware comes from the installed `armbian-firmware`:
  `brcm/brcmfmac43752-pcie.{bin,clm_blob,txt}` and `brcm/BCM4362A2.hcd`.
- `fdtput`/`fdtget` come from `device-tree-compiler`, which was already
  installed.

The previous ESP sync script and DTB are kept in `/root/*.before-ap6275p`.

The same script and service run on the Arch Linux ARM install on the M.2
SSD (`linux-aarch64` 7.2.11). There, on 2026-10-25:

- `0002:21:00.0 [14e4:449d]` enumerated;
- `brcmfmac` started firmware 18.35.387.23.146 and `wlP2p33s0` scanned
  2.4/5 GHz networks;
- Bluetooth reported `BCM43752A2 … AP6398` with `hci0` powered.

On PVE the files were installed from a chroot and the ESP DTB was
regenerated. A PVE boot with them has not been observed yet. The vendor
kernel is not affected: the DTB patch is applied only to the mainline
entry, and the service has `ConditionKernelVersion=!*-vendor-*`.

## Not available under mainline

- **ZFS** (no module; see above).
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
