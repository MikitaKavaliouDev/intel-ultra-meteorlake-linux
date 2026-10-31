#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect active swap partition UUID
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

echo "[1/6] Applying kernel arguments via grubby..."
# Remove rhgb/quiet (Plymouth must never contest KWin for DRM Master)
sudo grubby --update-kernel=ALL --remove-args="rhgb quiet"
# Apply resume target, Intel display transceiver stability, and nouveau/nova blacklists
sudo grubby --update-kernel=ALL --args="resume=UUID=${SWAP_UUID} i915.enable_psr=0 i915.fastboot=0 pm_async=0 rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core"

echo "[2/6] Masking Plymouth and NVIDIA fallback services..."
# Prevent nvidia-fallback from invoking Plymouth or racing DRM master at hibernate entry
sudo systemctl mask nvidia-fallback.service 2>/dev/null || true
sudo systemctl mask plymouth-start.service plymouth-suspend.service plymouth-hibernate.service 2>/dev/null || true

echo "[3/6] Installing PCIe udev rules & modprobe denylists..."
# Strip ALL NVIDIA PCI devices (GPU 0x03* AND Audio 0x0403*) on bus wake
sudo tee /etc/udev/rules.d/99-remove-all-nvidia.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{remove}="1"
EOF
sudo udevadm control --reload-rules

# Blacklist audio codec probe on NVIDIA subdevices
sudo tee -a /etc/modprobe.d/blacklist-nvidia.conf << 'EOF'
blacklist snd_hda_codec_hdmi
options snd_hda_intel enable=1,0
EOF

echo "[4/6] Enforcing UTC Hardware Clock..."
sudo timedatectl set-local-rtc 0

echo "[5/6] Configuring systemd sleep parameters..."
sudo mkdir -p /etc/systemd/sleep.conf.d
sudo tee /etc/systemd/sleep.conf.d/50-sleep-fix.conf << 'SLEEP_EOF'
[Sleep]
AllowSuspend=yes
AllowHibernation=yes
AllowSuspendThenHibernate=yes
HibernateMode=shutdown
HibernateDelaySec=15min
HibernateOnACPower=yes
SLEEP_EOF

echo "[6/6] Installing suspend-then-hibernate runner & drop-in..."
sudo install -m 0755 "${SCRIPT_DIR}/bin/suspend-then-hibernate-runner" /usr/local/bin/suspend-then-hibernate-runner

sudo mkdir -p /etc/systemd/system/systemd-suspend-then-hibernate.service.d
sudo tee /etc/systemd/system/systemd-suspend-then-hibernate.service.d/override-runner.conf << 'DROPIN_EOF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/suspend-then-hibernate-runner
DROPIN_EOF

sudo systemctl daemon-reload
echo "Installation complete!"
