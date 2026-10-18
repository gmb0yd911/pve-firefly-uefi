#!/usr/bin/env bash
# ==============================================================================
# build-uefi-image.sh
# Convert Proxmox VE ARM eMMC rootfs backup into an EDK2 UEFI bootable GPT image
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(dirname "${SCRIPT_DIR}")"
CACHE_DIR="${WORK_DIR}/cache"
OUTPUT_DIR="${WORK_DIR}/output"

ROOTFS_TAR="${1:-${CACHE_DIR}/pve-arm-firefly-rootfs.tar.zst}"
IMG_NAME="${2:-proxmox-ve-arm-firefly-uefi.img}"
IMG_FILE="${OUTPUT_DIR}/${IMG_NAME}"

IMG_SIZE_MIB="${IMG_SIZE_MIB:-12288}" # 12 GiB sparse image
ESP_SIZE_MIB="${ESP_SIZE_MIB:-512}"   # 512 MiB FAT32 EFI System Partition

echo "===================================================================="
echo " Proxmox VE ARM: EDK2 UEFI Image Builder (Firefly ITX-3588J)"
echo " Source Archive: ${ROOTFS_TAR}"
echo " Output Image:   ${IMG_FILE}"
echo " Image Size:     ${IMG_SIZE_MIB} MiB (Sparse)"
echo " ESP Size:       ${ESP_SIZE_MIB} MiB (FAT32)"
echo " Rootfs:         ext4"
echo " Bootloader:     systemd-boot (BOOTAA64.EFI) + Device Tree Stub"
echo "===================================================================="

# Check dependencies
for cmd in parted losetup mkfs.vfat mkfs.ext4 tar zstd blkid; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: Required command '$cmd' is not installed." >&2
    exit 1
  fi
done

if [[ ! -f "${ROOTFS_TAR}" ]]; then
  echo "Error: Source rootfs archive not found: ${ROOTFS_TAR}" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"

LOOP_DEV=""
MOUNT_ROOT=""
MOUNT_ESP=""

cleanup() {
  echo "Cleaning up mounts and loop devices..."
  sync
  set +e
  if [[ -n "${MOUNT_ESP}" ]] && mountpoint -q "${MOUNT_ESP}" 2>/dev/null; then
    sudo umount -f "${MOUNT_ESP}"
  fi
  if [[ -n "${MOUNT_ROOT}" ]] && mountpoint -q "${MOUNT_ROOT}" 2>/dev/null; then
    sudo umount -f "${MOUNT_ROOT}"
  fi
  if [[ -n "${MOUNT_ROOT}" && -d "${MOUNT_ROOT}" ]]; then
    rm -rf "${MOUNT_ROOT}"
  fi
  if [[ -n "${MOUNT_ESP}" && -d "${MOUNT_ESP}" ]]; then
    rm -rf "${MOUNT_ESP}"
  fi
  if [[ -n "${LOOP_DEV}" && -b "${LOOP_DEV}" ]]; then
    sudo losetup -d "${LOOP_DEV}" 2>/dev/null || true
  fi
  set -e
}
trap cleanup EXIT

# 1. Create sparse image file
echo "[1/6] Creating sparse disk image (${IMG_SIZE_MIB} MiB)..."
rm -f "${IMG_FILE}"
truncate -s "${IMG_SIZE_MIB}M" "${IMG_FILE}"

# 2. Partition with standard GPT
# Partition 1: FAT32 ESP (1MiB to 513MiB), boot & esp flags
# Partition 2: ext4 Linux filesystem (513MiB to 100%)
echo "[2/6] Partitioning disk image with standard UEFI GPT..."
parted -s "${IMG_FILE}" mklabel gpt
parted -s "${IMG_FILE}" mkpart primary fat32 1MiB "$((1 + ESP_SIZE_MIB))MiB"
parted -s "${IMG_FILE}" name 1 "EFI"
parted -s "${IMG_FILE}" set 1 boot on
parted -s "${IMG_FILE}" set 1 esp on
parted -s "${IMG_FILE}" mkpart primary ext4 "$((1 + ESP_SIZE_MIB))MiB" 100%
parted -s "${IMG_FILE}" name 2 "pve_root"

# 3. Attach loop device
echo "[3/6] Attaching loop device with partition scan..."
LOOP_DEV=$(sudo losetup -Pf --show "${IMG_FILE}")
echo "Attached: ${LOOP_DEV}"
sleep 1
if [[ ! -b "${LOOP_DEV}p1" || ! -b "${LOOP_DEV}p2" ]]; then
  sudo partx -u "${LOOP_DEV}" 2>/dev/null || true
  sleep 1
fi

# 4. Format partitions
echo "[4/6] Formatting partitions..."
sudo mkfs.vfat -F 32 -n "EFI" "${LOOP_DEV}p1"
sudo mkfs.ext4 -F -L "pve_root" "${LOOP_DEV}p2"

ESP_UUID=$(sudo blkid -s UUID -o value "${LOOP_DEV}p1")
ROOT_UUID=$(sudo blkid -s UUID -o value "${LOOP_DEV}p2")
echo "ESP UUID:  ${ESP_UUID}"
echo "ROOT UUID: ${ROOT_UUID}"

# 5. Extract Root Filesystem
echo "[5/6] Extracting Proxmox VE rootfs into root partition..."
MOUNT_ROOT=$(mktemp -d -p /tmp pve_root.XXXXXX)
sudo mount "${LOOP_DEV}p2" "${MOUNT_ROOT}"

# Extract all files preserving attributes, numeric ownership, xattrs, and ACLs
sudo tar --numeric-owner --xattrs --acls -xpaf "${ROOTFS_TAR}" -C "${MOUNT_ROOT}"

# 6. Configure EFI System Partition (ESP) & Bootloader
echo "[6/6] Populating EFI System Partition with kernel, DTB, and systemd-boot..."
MOUNT_ESP=$(mktemp -d -p /tmp pve_esp.XXXXXX)
sudo mount "${LOOP_DEV}p1" "${MOUNT_ESP}"

# Create ESP directory hierarchy
sudo mkdir -p "${MOUNT_ESP}/EFI/BOOT" \
              "${MOUNT_ESP}/EFI/systemd" \
              "${MOUNT_ESP}/loader/entries" \
              "${MOUNT_ESP}/dtb/rockchip"

# Copy ARM64 systemd-boot binary
BOOT_EFI="${CACHE_DIR}/systemd-bootaa64.efi"
if [[ -f "${BOOT_EFI}" ]]; then
  sudo cp "${BOOT_EFI}" "${MOUNT_ESP}/EFI/systemd/systemd-bootaa64.efi"
  sudo cp "${BOOT_EFI}" "${MOUNT_ESP}/EFI/BOOT/BOOTAA64.EFI"
else
  echo "Error: systemd-bootaa64.efi not found in ${CACHE_DIR}" >&2
  exit 1
fi

# Find kernel, initramfs, and DTB from extracted rootfs
KERNEL_SRC=$(ls -1 "${MOUNT_ROOT}/boot"/vmlinuz-* 2>/dev/null | head -n1 || true)
if [[ -z "${KERNEL_SRC}" || ! -f "${KERNEL_SRC}" ]]; then
  echo "Error: Kernel binary not found in rootfs /boot" >&2
  exit 1
fi
KERNEL_NAME=$(basename "${KERNEL_SRC}")
echo "Kernel: ${KERNEL_NAME}"
sudo cp "${KERNEL_SRC}" "${MOUNT_ESP}/${KERNEL_NAME}"

INITRD_SRC=$(ls -1 "${MOUNT_ROOT}/boot"/initrd.img-* 2>/dev/null | head -n1 || true)
if [[ -z "${INITRD_SRC}" || ! -f "${INITRD_SRC}" ]]; then
  echo "Error: Initramfs not found in rootfs /boot" >&2
  exit 1
fi
INITRD_NAME=$(basename "${INITRD_SRC}")
echo "Initrd: ${INITRD_NAME}"
sudo cp "${INITRD_SRC}" "${MOUNT_ESP}/${INITRD_NAME}"

# Locate the Firefly ITX-3588J Device Tree Blob
DTB_SRC=$(find "${MOUNT_ROOT}/boot" -name "rk3588-firefly-itx-3588j.dtb" | head -n1 || true)
if [[ -z "${DTB_SRC}" || ! -f "${DTB_SRC}" ]]; then
  if [[ -f "${CACHE_DIR}/rk3588-firefly-itx-3588j.dtb" ]]; then
    DTB_SRC="${CACHE_DIR}/rk3588-firefly-itx-3588j.dtb"
  else
    echo "Error: rk3588-firefly-itx-3588j.dtb not found!" >&2
    exit 1
  fi
fi
echo "Device Tree: ${DTB_SRC}"
sudo cp "${DTB_SRC}" "${MOUNT_ESP}/dtb/rockchip/rk3588-firefly-itx-3588j.dtb"

# Write systemd-boot loader configuration
sudo tee "${MOUNT_ESP}/loader/loader.conf" >/dev/null <<EOF
default proxmox.conf
timeout 3
console-mode max
editor no
EOF

# Write loader entry with RK3588 vendor cmdline arguments and device tree
sudo tee "${MOUNT_ESP}/loader/entries/proxmox.conf" >/dev/null <<EOF
title      Proxmox VE ARM 9 (Firefly ITX-3588J UEFI)
linux      /${KERNEL_NAME}
initrd     /${INITRD_NAME}
devicetree /dtb/rockchip/rk3588-firefly-itx-3588j.dtb
options    root=UUID=${ROOT_UUID} rootwait rw console=tty1 console=ttyS2,1500000 cma=256M cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory usb-storage.quirks=0x2537:0x1066:u,0x2537:0x1068:u
EOF

# Update rootfs /etc/fstab with the new UUIDs
sudo tee "${MOUNT_ROOT}/etc/fstab" >/dev/null <<EOF
# /etc/fstab: static file system information
# <file system>                            <mount point>   <type>  <options>                                 <dump>  <pass>
UUID=${ROOT_UUID}                          /               ext4    defaults,commit=120,errors=remount-ro     0       1
UUID=${ESP_UUID}                           /boot           vfat    defaults,umask=0077                       0       2
tmpfs                                      /tmp            tmpfs   defaults,nosuid                           0       0
EOF

# Ensure symlinks in rootfs /vmlinuz and /initrd.img point to boot/${KERNEL_NAME}
sudo ln -sf "boot/${KERNEL_NAME}" "${MOUNT_ROOT}/vmlinuz"
sudo ln -sf "boot/${INITRD_NAME}" "${MOUNT_ROOT}/initrd.img"

sync
echo "===================================================================="
echo " Proxmox VE ARM UEFI Image Built Successfully!"
echo " Image: ${IMG_FILE}"
echo " Size:  $(du -h "${IMG_FILE}" | cut -f1) actual / ${IMG_SIZE_MIB} MiB virtual"
echo "===================================================================="
