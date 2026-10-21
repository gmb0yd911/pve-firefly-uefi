#!/usr/bin/env bash
# ==============================================================================
# deploy-uefi-image.sh
# Stream and flash the Proxmox VE ARM UEFI image directly to the Firefly board
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(dirname "${SCRIPT_DIR}")"
OUTPUT_DIR="${WORK_DIR}/output"

SSH_TARGET="${1:-firefly}"
TARGET_DEV="${2:-/dev/mmcblk0}" # Default target: eMMC
[[ $TARGET_DEV =~ ^/dev/(mmcblk[0-9]+|sd[a-z]+|nvme[0-9]+n[0-9]+)$ ]] || {
  echo "Error: Specify a whole disk device, such as /dev/mmcblk0." >&2
  exit 1
}

ssh_target() {
  ssh -F "${SSH_CONFIG:-${HOME}/.ssh/config}" -o ConnectTimeout=10 "${SSH_TARGET}" "$@"
}

IMG_FILE=$(ls -1 "${OUTPUT_DIR}"/proxmox-ve-arm-firefly-uefi.img.zst \
                 "${OUTPUT_DIR}"/proxmox-ve-arm-firefly-uefi.img 2>/dev/null | head -n1 || true)

echo "===================================================================="
echo " Proxmox VE ARM: Remote UEFI Image Deployer"
echo " Host:         ${SSH_TARGET}"
echo " Target Drive: ${TARGET_DEV}"
echo " Source Image: ${IMG_FILE}"
echo "===================================================================="

if [[ -z "${IMG_FILE}" || ! -f "${IMG_FILE}" ]]; then
  echo "Error: UEFI image not found in ${OUTPUT_DIR}." >&2
  echo "Run ./scripts/build-uefi-image.sh first." >&2
  exit 1
fi

# 1. Test SSH connectivity
echo "Checking connection to ${SSH_TARGET}..."
ssh_target "hostname && uname -a"

# Run before any unmount or write, even when the live root is on another disk.
# Booting Omarchy from SATA does not mean eMMC firmware can be overwritten.
ssh_target "sudo -n python3 - '${TARGET_DEV}'" < "${SCRIPT_DIR}/check-firmware-header.py"

# 2. Safety check: Ensure target drive is NOT the currently mounted root drive
echo "Verifying target drive safety..."
ssh_target bash <<CHECKSAFETY
  set -e
  ROOT_DEV=\$(findmnt -n -o SOURCE / || true)
  if [[ "\${ROOT_DEV}" == "${TARGET_DEV}"* ]]; then
    echo "ERROR: Target drive ${TARGET_DEV} is currently mounted as ROOT (\${ROOT_DEV})!" >&2
    echo "Refusing to overwrite the currently running root operating system." >&2
    exit 1
  fi
  # Unmount any partitions from the target drive
  for mnt in \$(lsblk -n -o MOUNTPOINT "${TARGET_DEV}" 2>/dev/null | grep -v '^$'); do
    echo "Unmounting partition: \${mnt}"
    sudo umount -f "\${mnt}" || true
  done
CHECKSAFETY

echo ""
echo "===================================================================="
echo " WARNING: ALL DATA ON ${TARGET_DEV} ON ${SSH_TARGET} WILL BE OVERWRITTEN!"
echo " Target: ${TARGET_DEV}"
echo "===================================================================="
read -p "Type 'yes' to proceed with flashing: " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
  echo "Flashing cancelled by user."
  exit 0
fi

echo "Streaming image to ${TARGET_DEV}..."
if [[ "${IMG_FILE}" == *.zst ]]; then
  zstd -dc "${IMG_FILE}" | ssh_target "sudo dd of=${TARGET_DEV} bs=4M status=progress conv=fsync"
else
  cat "${IMG_FILE}" | ssh_target "sudo dd of=${TARGET_DEV} bs=4M status=progress conv=fsync"
fi

echo "Fixing GPT secondary header at disk end..."
ssh_target bash <<EXPAND
  set -e
  # Repair GPT header location
  sudo sgdisk -e "${TARGET_DEV}" 2>/dev/null || sudo parted -s "${TARGET_DEV}" ---pretend-input-tty print Fix || true
  sudo partprobe "${TARGET_DEV}" || true
  sleep 2

  echo "Expanding root partition to fill drive capacity..."
  # Determine root partition number (partition 2)
  sudo parted -s "${TARGET_DEV}" resizepart 2 100% || true
  sudo partprobe "${TARGET_DEV}" || true
  sleep 2

  # Determine partition device path (e.g., mmcblk0p2 vs sda2)
  ROOT_PART="${TARGET_DEV}p2"
  if [[ ! -b "\${ROOT_PART}" ]]; then
    ROOT_PART="${TARGET_DEV}2"
  fi

  if [[ -b "\${ROOT_PART}" ]]; then
    echo "Resizing ext4 filesystem on \${ROOT_PART}..."
    sudo e2fsck -fy "\${ROOT_PART}" || true
    sudo resize2fs "\${ROOT_PART}" || true
  fi

  echo "Verifying new partition layout:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID "${TARGET_DEV}"
EXPAND

echo "===================================================================="
echo " Proxmox VE ARM UEFI Image Deployed Successfully!"
echo " Target: ${TARGET_DEV} on ${SSH_TARGET}"
echo "===================================================================="
