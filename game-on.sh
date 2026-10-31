sudo tee /usr/local/bin/game-on << 'EOF'
#!/usr/bin/env bash
set -e

CURRENT=$(envycontrol -q 2>/dev/null || echo "unknown")

if [ "$CURRENT" = "hybrid" ]; then
    echo "You are already in Gaming (Hybrid) mode!"
    exit 0
fi

echo "=================================================="
echo " Preparing to switch to GAMING MODE (NVIDIA Active)"
echo "=================================================="

# 1. Switch EnvyControl to Hybrid mode for full GPU power
sudo envycontrol -s hybrid

# 2. Re-enable NVIDIA PCIe devices: remove the everyday total strip rule
sudo rm -f /etc/udev/rules.d/99-remove-all-nvidia.rules
sudo rm -f /etc/modprobe.d/blacklist-nvidia-audio.conf
sudo udevadm control --reload-rules 2>/dev/null || true

# 3. SAFETY: Lock hibernation to prevent proprietary driver teardown crashes
sudo systemctl mask systemd-hibernate.service systemd-suspend-then-hibernate.service 2>/dev/null

echo ""
echo "EnvyControl configured for NVIDIA gaming."
echo "NVIDIA PCIe GPU and HDMI Audio will enumerate normally."
echo "Hibernation has been SAFELY LOCKED for this session."
echo ""
read -p "Reboot now to enter Gaming Mode? [Y/n] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
    sudo reboot
fi
EOF
sudo chmod +x /usr/local/bin/game-on