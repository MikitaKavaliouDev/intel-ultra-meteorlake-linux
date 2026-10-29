#!/usr/bin/env bash
set -euo pipefail

# Detect the active swap partition UUID
SWAP_DEVICE="$(swapon --show=NAME --noheadings | awk 'NR==1{print $1}')"
if [[ -z "${SWAP_DEVICE}" ]]; then
    echo "No active swap partition found. Aborting." >&2
    exit 1
fi
SWAP_UUID="$(blkid -s UUID -o value "${SWAP_DEVICE}")"
if [[ -z "${SWAP_UUID}" ]]; then
    echo "Could not determine UUID for ${SWAP_DEVICE}. Aborting." >&2
    exit 1
fi

# Kernel Arguments Section

# Ensure rhgb and quiet are purged
sudo grubby --update-kernel=ALL --remove-args="rhgb quiet"

# Apply the golden kernel line
sudo grubby --update-kernel=ALL --args="resume=UUID=${SWAP_UUID} i915.enable_psr=0 i915.fastboot=0 pm_async=0 rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core"
