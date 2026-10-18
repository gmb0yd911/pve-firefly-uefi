#!/usr/bin/env bash
# ==============================================================================
# restore-uboot-emmc.sh
# Restore the original U-Boot and partition structure to the eMMC (/dev/mmcblk0)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(dirname "${SCRIPT_DIR}")"
CACHE_DIR="${WORK_DIR}/cache"

SSH_TARGET="${1:-firefly}"
TARGET_DEV="${2:-/dev/mmcblk0}"

BOOT_HEADER="${CACHE_DIR}/emmc-u-boot-header-16M.bin"
ROOTFS_TAR="${CACHE_DIR}/pve-arm-firefly-rootfs.tar.zst"

echo "===================================================================="
echo " Restore Original U-Boot & eMMC System (Firefly ITX-3588J)"
echo " Host:           ${SSH_TARGET}"
echo " Target Device:  ${TARGET_DEV}"
echo " Bootloader:     ${BOOT_HEADER}"
echo " Rootfs Archive: ${ROOTFS_TAR}"
echo "===================================================================="

if [[ ! -f "${BOOT_HEADER}" || ! -f "${ROOTFS_TAR}" ]]; then
  echo "Error: Required backup files missing from ${CACHE_DIR}." >&2
  exit 1
fi

# 1. Test SSH
echo "Checking connection to ${SSH_TARGET}..."
ssh -o ConnectTimeout=5 "${SSH_TARGET}" "hostname && uname -a"

# 2. Safety check
ssh "${SSH_TARGET}" bash <<CHECKSAFETY
  set -e
  ROOT_DEV=\$(findmnt -n -o SOURCE / || true)
  if [[ "\${ROOT_DEV}" == "${TARGET_DEV}"* ]]; then
    echo "ERROR: Target drive ${TARGET_DEV} is currently mounted as ROOT (\${ROOT_DEV})!" >&2
    exit 1
  fi
  for mnt in \$(lsblk -n -o MOUNTPOINT "${TARGET_DEV}" 2>/dev/null | grep -v '^$'); do
    echo "Unmounting partition: \${mnt}"
    sudo umount -f "\${mnt}" || true
  done
CHECKSAFETY

echo ""
echo "WARNING: Restoring will overwrite ${TARGET_DEV} with original U-Boot and PVE rootfs."
read -p "Type 'yes' to proceed: " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
  echo "Restore cancelled."
  exit 0
fi

# 1. Restore the 16MB raw bootloader header (idbloader + uboot.itb + partition table)
echo "Writing original U-Boot bootloader header (16 MiB)..."
cat "${BOOT_HEADER}" | ssh "${SSH_TARGET}" "sudo dd of=${TARGET_DEV} bs=1M count=16 status=progress conv=fsync"

# 2. Inform kernel of partition layout
ssh "${SSH_TARGET}" "sudo partprobe ${TARGET_DEV} && sleep 2"

# 3. Format ext4 partition 1 with original UUID
PART_DEV="${TARGET_DEV}p1"
if [[ ! -b "${PART_DEV}" ]]; then
  PART_DEV="${TARGET_DEV}1"
fi

ORIGINAL_UUID="5cb1c8d4-172b-4fb7-8c5a-52a601ad5fa0"
echo "Formatting ${PART_DEV} with original UUID (${ORIGINAL_UUID})..."
ssh "${SSH_TARGET}" "sudo mkfs.ext4 -F -L 'armbi_root' -U '${ORIGINAL_UUID}' ${PART_DEV}"

# 4. Extract rootfs into the partition
echo "Extracting original Proxmox VE rootfs..."
ssh "${SSH_TARGET}" bash <<RESTOREFS
  set -e
  RESTORE_DIR=\$(mktemp -d -p /tmp restore_pve.XXXXXX)
  sudo mount "${PART_DEV}" "\${RESTORE_DIR}"
  sudo tar --numeric-owner --xattrs --acls -xpaf /home/alarm/backup/pve-arm-firefly-rootfs.tar.zst -C "\${RESTORE_DIR}"
  
  # Ensure armbianEnv.txt has original standalone rootdev setting
  if [[ -f "\${RESTORE_DIR}/boot/armbianEnv.txt.emmc-bak" ]]; then
    sudo cp "\${RESTORE_DIR}/boot/armbianEnv.txt.emmc-bak" "\${RESTORE_DIR}/boot/armbianEnv.txt"
  fi
  
  sync
  sudo umount "\${RESTORE_DIR}"
  rm -rf "\${RESTORE_DIR}"
  echo "Rootfs restored successfully."
RESTOREFS

echo "===================================================================="
echo " Original U-Boot & eMMC System Restored Successfully!"
echo "===================================================================="
