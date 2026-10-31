sudo tee /usr/local/bin/game-off << 'EOF'
#!/usr/bin/env bash
set -e

CURRENT=$(envycontrol -q 2>/dev/null || echo "unknown")

if [ "$CURRENT" = "integrated" ]; then
    echo "You are already in Everyday (Intel-Only 0W) mode!"
    exit 0
fi

echo "=================================================="
echo " Returning to EVERYDAY MODE (Intel-Only 0W)"
echo "=================================================="

# 1. Switch EnvyControl back to integrated (VGA removal rule)
sudo envycontrol -s integrated

# 2. Re-apply total PCIe cut (strips GPU + Audio on wake) to prevent sleep deadlocks
sudo tee /etc/udev/rules.d/99-remove-all-nvidia.rules << 'RULE_EOF'
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{remove}="1"
RULE_EOF

# 3. Denylist HDMI audio codec to avoid probe errors on sleep transitions
sudo tee /etc/modprobe.d/blacklist-nvidia-audio.conf << 'MOD_EOF'
blacklist snd_hda_codec_hdmi
options snd_hda_intel enable=1,0
MOD_EOF

sudo udevadm control --reload-rules 2>/dev/null || true

# 4. RESTORE: Unlock hibernation and suspend-then-hibernate
sudo systemctl unmask systemd-hibernate.service systemd-suspend-then-hibernate.service 2>/dev/null

echo ""
echo "NVIDIA dGPU & Audio will be completely stripped on boot (True 0-Watt idle)."
echo "Hibernation & Suspend-then-Hibernate are UNLOCKED."
echo ""
read -p "Reboot now to return to Everyday Mode? [Y/n] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
    sudo reboot
fi
EOF
sudo chmod +x /usr/local/bin/game-off