#!/usr/bin/env bash
# ==============================================================================
# flash-spi-nor-edk2.sh
# Flash official EDK2 UEFI firmware to the SPI NOR flash on Firefly ITX-3588J
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(dirname "${SCRIPT_DIR}")"
CACHE_DIR="${WORK_DIR}/cache"

FIRMWARE_IMG="${CACHE_DIR}/itx-3588j_UEFI_Release_v1.1.img"
SSH_TARGET="${1:-firefly}"

echo "===================================================================="
echo " Firefly ITX-3588J: EDK2 UEFI SPI NOR Flasher"
echo " Host:           ${SSH_TARGET}"
echo " Firmware Image: ${FIRMWARE_IMG}"
echo "===================================================================="

if [[ ! -f "${FIRMWARE_IMG}" ]]; then
  echo "Downloading EDK2 UEFI v1.1 firmware image..."
  mkdir -p "${CACHE_DIR}"
  curl -L -o "${FIRMWARE_IMG}" "https://github.com/edk2-porting/edk2-rk3588/releases/download/v1.1/itx-3588j_UEFI_Release_v1.1.img"
fi

# 1. Check SSH connectivity
echo "Checking connection to ${SSH_TARGET}..."
ssh -o ConnectTimeout=5 "${SSH_TARGET}" "hostname && uname -a"

# 2. Check for MTD SPI NOR device on the board
echo "Checking for SPI NOR flash device on ${SSH_TARGET}..."
MTD_DEV=$(ssh "${SSH_TARGET}" "grep -l 'spi' /sys/class/mtd/mtd*/name 2>/dev/null | head -n1 || true")
if [[ -n "${MTD_DEV}" ]]; then
  DEV_NAME=$(basename "$(dirname "${MTD_DEV}")")
  echo "Found MTD SPI NOR device: /dev/${DEV_NAME}"
  
  echo "WARNING: Writing EDK2 UEFI firmware directly to /dev/${DEV_NAME} on ${SSH_TARGET}!"
  read -p "Type 'yes' to proceed: " CONFIRM
  if [[ "${CONFIRM}" == "yes" ]]; then
    cat "${FIRMWARE_IMG}" | ssh "${SSH_TARGET}" "sudo dd of=/dev/${DEV_NAME} bs=4k status=progress conv=fsync"
    echo "EDK2 UEFI flashed successfully to SPI NOR!"
    exit 0
  fi
fi

# 3. If MTD device is not active in running kernel
echo ""
echo "Notice: No active /dev/mtd device for SPI NOR was detected in the running Linux kernel."
echo "On Rockchip RK3588, the SPI NOR flash controller (SFC / spi@fe2b0000) can be flashed"
echo "using one of two standard methods:"
echo ""
echo "METHOD A: USB Type-C OTG MaskRom Mode (Direct Hardware Flash):"
echo "  1. Connect a USB-C cable from this PC to the Type-C OTG port on the ITX-3588J."
echo "  2. Power off the board."
echo "  3. Hold down the MASKROM (or RECOVERY) button on the board, and connect power."
echo "  4. Verify with: rkdeveloptool ld"
echo "  5. Flash the firmware image to SPI NOR:"
echo "       rkdeveloptool db cache/rk3588_spl_loader.bin"
echo "       rkdeveloptool wl 0 ${FIRMWARE_IMG}"
echo "       rkdeveloptool rd"
echo ""
echo "METHOD B: Flash EDK2 directly to eMMC /dev/mmcblk0 (Software UEFI):"
echo "  If your board does not have a physical SPI NOR chip populated, you can"
echo "  flash EDK2 directly to the eMMC or SD card bootloader sector:"
echo "    cat ${FIRMWARE_IMG} | ssh ${SSH_TARGET} 'sudo dd of=/dev/mmcblk0 bs=4M status=progress conv=fsync'"
echo ""
echo "See docs/spi-nor-flashing.md for full step-by-step instructions."
