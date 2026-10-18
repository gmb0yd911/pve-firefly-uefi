# Proxmox VE ARM: UEFI Boot Architecture (Firefly ITX-3588J)

This document describes how the Proxmox VE ARM system has been backed up and transformed from the vendor U-Boot flow to a modern, standard EDK2 UEFI boot architecture on the **Firefly ITX-3588J** (Rockchip RK3588).

---

## 1. Traditional Rockchip U-Boot vs. EDK2 UEFI Architecture

### Legacy U-Boot Architecture (Original eMMC)
In the default Firefly installation on eMMC (`/dev/mmcblk0`):
- **Raw Bootloader Offsets**: Rockchip BootROM loads `idbloader.img` directly from sector 64 and `uboot.itb` from sector 16384 (within the first 16 MiB).
- **Partition Layout**: Single large ext4 partition (`/dev/mmcblk0p1`) starting at sector 32768.
- **Boot Flow**: U-Boot executes `boot.scr` / `armbianEnv.txt`, manually loads the kernel (`Image`), Device Tree (`.dtb`), and initramfs (`uInitrd`) into physical RAM addresses, and executes `booti`.
- **Limitation**: Any attempt to boot another operating system or drive (like SATA SSD `/dev/sda` or NVMe) requires U-Boot on eMMC to chainload or redirect bootargs, or requires flashing U-Boot directly to the other drive.

```
Original eMMC Disk Layout:
[Sectors 0-32767: MBR + Rockchip SPL & U-Boot ITB (16 MiB)]
└── Partition 1: Linux ext4 (230.6 GiB)
    ├── /boot/armbianEnv.txt
    ├── /boot/boot.scr
    ├── /boot/vmlinuz-6.1.115-vendor-rk35xx
    ├── /boot/initrd.img-6.1.115-vendor-rk35xx
    └── Root filesystem (Proxmox VE 9 ARM packages, services)
```

---

### Modern EDK2 UEFI Architecture (Standard PC Flow)
When **EDK2 UEFI** (`edk2-rk3588`) is flashed to SPI NOR:
- **Firmware in Hardware**: The Rockchip BootROM executes EDK2 UEFI from SPI NOR. EDK2 acts like a conventional PC BIOS/UEFI firmware.
- **Standard GPT Partitioning**: No special raw sectors are required on the disk. The drive uses standard GPT partitions.
- **EFI System Partition (ESP)**: A 512 MiB FAT32 partition flagged with `boot, esp` contains standard UEFI binaries.
- **systemd-boot (BOOTAA64.EFI)**: EDK2 executes `\EFI\BOOT\BOOTAA64.EFI`, which reads `/loader/entries/proxmox.conf`.
- **Native Kernel EFI Stub**: The vendor kernel (`vmlinuz-6.1.115-vendor-rk35xx`) has `CONFIG_EFI_STUB=y` and `CONFIG_EFI_ARMSTUB_DTB_LOADER=y` enabled. It is executed directly as a PE/COFF ARM64 EFI binary.
- **Device Tree**: EDK2 passes the hardware Device Tree (`dtb/rockchip/rk3588-firefly-itx-3588j.dtb`) to the kernel, ensuring full hardware support (Mali G610 GPU, VOP2 HDMI, PCIe, SATA, and NPU).

```
EDK2 UEFI Disk Layout:
[Standard Protective MBR + GPT Header (1 MiB)]
├── Partition 1: 512 MiB FAT32 EFI System Partition (ESP) [/boot]
│   ├── EFI/BOOT/BOOTAA64.EFI (systemd-boot ARM64)
│   ├── EFI/systemd/systemd-bootaa64.efi
│   ├── loader/
│   │   ├── loader.conf
│   │   └── entries/proxmox.conf
│   ├── dtb/rockchip/rk3588-firefly-itx-3588j.dtb
│   ├── vmlinuz-6.1.115-vendor-rk35xx
│   └── initrd.img-6.1.115-vendor-rk35xx
└── Partition 2: Remainder Linux ext4 [pve_root] [/]
    ├── Root filesystem (Proxmox VE 9 ARM, Debian 13 Trixie)
    ├── /etc/fstab (UUID mapping for / and /boot)
    └── Symlinks: /vmlinuz -> boot/vmlinuz-... and /initrd.img -> boot/initrd.img-...
```

---

## 2. Kernel & System Configuration

### Kernel Command Line Options
Configured in `/boot/loader/entries/proxmox.conf`:
```ini
title      Proxmox VE ARM 9 (Firefly ITX-3588J UEFI)
linux      /vmlinuz-6.1.115-vendor-rk35xx
initrd     /initrd.img-6.1.115-vendor-rk35xx
devicetree /dtb/rockchip/rk3588-firefly-itx-3588j.dtb
options    root=UUID=<ROOT_UUID> rootwait rw console=tty1 console=ttyS2,1500000 cma=256M cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory usb-storage.quirks=0x2537:0x1066:u,0x2537:0x1068:u
```

### Essential Parameters:
- `root=UUID=<ROOT_UUID>`: Mounts root filesystem by UUID, allowing the image to boot seamlessly from eMMC (`/dev/mmcblk0`), SATA SSD (`/dev/sda`), NVMe SSD (`/dev/nvme0n1`), or external USB storage.
- `rootwait`: Waits for asynchronous block device discovery to settle before mounting root.
- `console=tty1 console=ttyS2,1500000`: Enables both HDMI video output (`tty1`) and onboard UART serial debugging (`ttyS2`).
- `cma=256M`: Contiguous Memory Allocation required for Rockchip 4K/8K VPU and camera pipelines.
- `cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory`: Required for Proxmox VE LXC container memory limits and Docker/Kubernetes runtime.
- `usb-storage.quirks`: Resolves Rockchip USB 3.0 bridge controller timeouts.

---

## 3. Preserved Proxmox VE System State
The captured system includes:
- **Base OS**: Debian GNU/Linux 13 (Trixie), kernel `6.1.115-vendor-rk35xx`.
- **Proxmox Components**:
  - `pve-manager` 9.2.20
  - `pve-qemu-kvm` 11.1.1-2
  - `lxc-pve` 7.0.0-2
  - `pve-cluster` 9.1.6
  - ZFS and LVM storage stacks
- **Web UI & Network**:
  - Static IP: `192.168.4.243/24` on interface `end0`
  - Web Console: `https://192.168.4.243:8006/`
  - User accounts, SSH keys, and sudo privileges are 100% retained.
