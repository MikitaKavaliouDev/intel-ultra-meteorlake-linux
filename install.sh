#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run this installer as root (sudo ./install.sh)"
    exit 1
fi

echo "=================================================================="
echo " PCSpecialist Ionico II 16 Linux Power Management Installer      "
echo "=================================================================="

# 1. Detect Swap Partition & UUID
SWAP_DEV=$(swapon --show=NAME --noheadings | head -n 1)
if [ -z "$SWAP_DEV" ]; then
    echo "Error: No active swap partition detected!"
    echo "Please configure an active physical swap partition (>= 64GB) before running."
    exit 1
fi

SWAP_UUID=$(lsblk -no UUID "$SWAP_DEV")
echo "[+] Detected active swap: $SWAP_DEV (UUID: $SWAP_UUID)"

# 2. Configure Kernel Arguments via grubby
echo "[+] Applying kernel parameters..."
sudo grubby --update-kernel=ALL --remove-args="rhgb quiet no_console_suspend ignore_loglevel initcall_debug" 2>/dev/null || true
sudo grubby --update-kernel=ALL --args="resume=UUID=${SWAP_UUID} i915.enable_psr=0 pm_async=0 pcie_ports=compat rtc_cmos.use_acpi_alarm=1 rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core"

# Clean /etc/default/grub
sudo sed -i -E 's/(rhgb|quiet)//g' /etc/default/grub 2>/dev/null || true

# 3. Configure Sleep Settings & tmpfiles
echo "[+] Configuring systemd sleep drop-ins..."
mkdir -p /etc/systemd/sleep.conf.d /etc/tmpfiles.d

cat << 'EOF' > /etc/systemd/sleep.conf.d/50-sleep-fix.conf
[Sleep]
AllowSuspend=yes
AllowHibernation=yes
AllowSuspendThenHibernate=yes
HibernateMode=shutdown
HibernateDelaySec=15min
HibernateOnACPower=yes
EOF

cat << 'EOF' > /etc/tmpfiles.d/hibernatemode.conf
w /sys/power/disk - - - - shutdown
EOF

# 4. KWin Wayland Display Resume Drop-Ins
echo "[+] Configuring KWin Wayland sleep service drop-ins..."
mkdir -p /etc/systemd/system/systemd-hibernate.service.d \
         /etc/systemd/system/systemd-suspend.service.d \
         /etc/systemd/system/systemd-suspend-then-hibernate.service.d

cat << 'EOF' > /etc/systemd/system/systemd-hibernate.service.d/kwin-fix.conf
[Service]
Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0
EOF

ln -sf /etc/systemd/system/systemd-hibernate.service.d/kwin-fix.conf /etc/systemd/system/systemd-suspend.service.d/kwin-fix.conf
ln -sf /etc/systemd/system/systemd-hibernate.service.d/kwin-fix.conf /etc/systemd/system/systemd-suspend-then-hibernate.service.d/kwin-fix.conf

# 5. Mask Plymouth sleep units
systemctl mask plymouth-hibernate.service plymouth-suspend.service plymouth-start.service 2>/dev/null || true

# 6. Install the Hardware-Aware Lid Runner
echo "[+] Installing suspend-then-hibernate-runner..."
cat << 'EOF' > /usr/local/bin/suspend-then-hibernate-runner
#!/usr/bin/env bash

CONF_DELAY=$(grep -E '^HibernateDelaySec=' /etc/systemd/sleep.conf.d/*.conf 2>/dev/null | tail -n 1 | cut -d= -f2 | tr -d ' ')
CONF_DELAY=${CONF_DELAY:-15min}

case "$CONF_DELAY" in
    *s) SECS="${CONF_DELAY%s}" ;;
    *min|*m) SECS=$(( ${CONF_DELAY%m*} * 60 )) ;;
    *h) SECS=$(( ${CONF_DELAY%h} * 3600 )) ;;
    *) SECS="$CONF_DELAY" ;;
esac

RTC_OPTS=""
if timedatectl 2>/dev/null | grep -qi "RTC in local TZ: yes"; then
    RTC_OPTS="-l"
fi

echo disable > /sys/firmware/acpi/interrupts/gpe6B 2>/dev/null || true
echo disable > /sys/firmware/acpi/interrupts/gpe6E 2>/dev/null || true

echo "[*] suspend-then-hibernate: Delay set to ${SECS}s. Arming RTC wake alarm..."
rtcwake $RTC_OPTS -m no -s "$SECS"

START_TIME=$(date +%s)

/usr/lib/systemd/systemd-sleep suspend

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
THRESHOLD=$(( SECS - 5 ))

echo "[*] System woke up. Elapsed sleep duration: ${ELAPSED}s (Target: ${SECS}s)"

LID_CLOSED=false
for state in /proc/acpi/button/lid/*/state; do
    if [ -r "$state" ] && grep -qi 'closed' "$state"; then
        LID_CLOSED=true
        break
    fi
done

if [ "$LID_CLOSED" = "false" ] && command -v busctl &>/dev/null; then
    UP_STATE=$(busctl get-property org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower LidIsClosed 2>/dev/null || true)
    case "$UP_STATE" in
        *true*) LID_CLOSED=true ;;
    esac
fi

if [ "$ELAPSED" -ge "$THRESHOLD" ] || [ "$LID_CLOSED" = "true" ]; then
    echo "[!] Target reached or lid closed. Allowing 3s for bus events to settle..."
    sleep 3
    echo disable > /sys/firmware/acpi/interrupts/gpe6B 2>/dev/null || true
    echo disable > /sys/firmware/acpi/interrupts/gpe6E 2>/dev/null || true
    echo "[!] Transitioning to 0-Watt Hibernation..."
    /usr/lib/systemd/systemd-sleep hibernate
else
    echo "[✓] System was woken by user opening the lid. Returning to desktop."
fi
EOF
chmod +x /usr/local/bin/suspend-then-hibernate-runner

# Hook runner into services
cat << 'EOF' > /etc/systemd/system/systemd-suspend-then-hibernate.service.d/override-runner.conf
[Service]
ExecStart=
ExecStart=/usr/local/bin/suspend-then-hibernate-runner
EOF

cat << 'EOF' > /etc/systemd/system/systemd-suspend.service.d/override-to-suspend-then-hibernate.conf
[Service]
Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0
ExecStart=
ExecStart=/usr/local/bin/suspend-then-hibernate-runner
EOF

# 7. Configure Logind Lid Handling
mkdir -p /etc/systemd/logind.conf.d
cat << 'EOF' > /etc/systemd/logind.conf.d/lid-hibernate.conf
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend-then-hibernate
HandleLidSwitchDocked=ignore
EOF

# 8. User KWin Environment
USER_HOME=$(eval echo "~${SUDO_USER}")
if [ -d "$USER_HOME" ]; then
    mkdir -p "$USER_HOME/.config/environment.d"
    echo "KWIN_DRM_NO_AMS=0" > "$USER_HOME/.config/environment.d/kwin.conf"
    chown -R "${SUDO_USER}:${SUDO_USER}" "$USER_HOME/.config/environment.d"
fi

systemctl daemon-reload
echo "=================================================================="
echo " Installation Complete! Please reboot to apply kernel arguments.  "
echo "=================================================================="
