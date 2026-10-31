# Comprehensive Guide: Suspend-Then-Hibernate on Fedora (KDE Plasma 6 Wayland)
### Intel Core Ultra 9 275HX (Arrow Lake-HX) + NVIDIA RTX 5060 Mobile

---

## 1. Overview & Target Behavior

This guide documents the battle-tested configuration required to achieve rock-solid **Suspend-then-Hibernate** on modern Intel Arrow Lake / Tongfang hybrid laptops running **Fedora**, **KDE Plasma 6 (Wayland)**, and **systemd**.

### Expected Hardware Lifecycle:
1. **Immediate Sleep:** Closing the lid (on battery or charger) suspends to RAM (`s2idle`) instantly. The power LED pulses slowly.
2. **15-Minute Timer:** The internal RTC hardware alarm is set for **15 minutes**.
3. **Automated Handoff:** After 15 minutes, the system wakes silently with the screen off. The custom runner script verifies that the timer expired (or the lid is still closed in a bag), allows the PCIe bus 3 seconds to settle, compresses RAM to the NVMe swap partition at >600 MB/s, and powers off completely (**true 0.0W Hibernation**; LED turns off).
4. **Clean Wake-up:** Pressing the power button restores your desktop session, open windows, and terminals in ~8 seconds without black screens or compositor freezes.
5. **On-Demand Gaming (`game-on` / `game-off`):** When you want to game on the dedicated NVIDIA GPU, a single command switches EnvyControl and automatically locks hibernation so driver teardown crashes can never occur.

---

## 2. Tested Hardware Baseline

| Component | Tested Specification |
| :--- | :--- |
| **Chassis** | PCSpecialist Ionico II 16 (Uniwill GM6HG / Tongfang) |
| **Processor** | Intel Core Ultra 9 275HX (24 Cores / 24 Threads) @ 5.40 GHz |
| **Integrated GPU** | Intel Arc Graphics / Xe-LPG (Device ID `7d67`) |
| **Discrete GPU** | NVIDIA GeForce RTX 5060 Mobile |
| **RAM** | 64 GB DDR5 |
| **Swap Target** | 66.4 GB Dedicated NVMe Partition (`/dev/nvme0n1p7`) |
| **Operating System** | Fedora Linux 44 (x86_64) • Kernel 7.2.x+ |
| **Desktop Environment** | KDE Plasma 6.7+ on KWin (Wayland) |

---

## 3. Step-by-Step Configuration

### Step 1: Configure Swap Partition & Kernel Resume Target

1. Find the UUID of your active physical swap partition:
   ```bash
   SWAP_DEV=$(swapon --show=NAME --noheadings | head -n 1)
   SWAP_UUID=$(lsblk -no UUID "$SWAP_DEV")
   echo "Active Swap Partition: $SWAP_DEV (UUID: $SWAP_UUID)"
   ```

2. Ensure `/etc/fstab` mounts the swap partition via this UUID:
   ```text
   UUID=YOUR_SWAP_UUID none swap defaults 0 0
   ```

3. Remove `rhgb quiet` and apply the golden kernel arguments:
   ```bash
   # Remove graphical boot splash (prevents KWin DRM Master collision)
   sudo grubby --update-kernel=ALL --remove-args="rhgb quiet"

   # Apply resume target, PCIe compatibility, and display flags
   sudo grubby --update-kernel=ALL --args="resume=UUID=${SWAP_UUID} i915.enable_psr=0 pm_async=0 pcie_ports=compat rtc_cmos.use_acpi_alarm=1 rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core"
   ```

   * **`pcie_ports=compat`:** Disables native PCIe hotplug (`pciehp`), stopping the detached NVIDIA GPU from re-enumerating and deadlocking the bus upon wake from $S0\text{ix}$ suspend.
   * **`i915.enable_psr=0`:** Disables Panel Self Refresh to ensure the display transceiver wakes reliably.
   * **`pm_async=0`:** Enforces synchronous driver wake-up to prevent race conditions.
   * **`rtc_cmos.use_acpi_alarm=1`:** Ensures the hardware RTC alarm fires reliably across dual-boot clock configurations.

---

### Step 2: Systemd Sleep Configuration Drop-Ins

1. **Configure sleep modes and timer:**
   ```bash
   sudo mkdir -p /etc/systemd/sleep.conf.d
   sudo tee /etc/systemd/sleep.conf.d/50-sleep-fix.conf << 'EOF'
   [Sleep]
   AllowSuspend=yes
   AllowHibernation=yes
   AllowSuspendThenHibernate=yes
   HibernateMode=shutdown
   HibernateDelaySec=15min
   HibernateOnACPower=yes
   EOF
   ```

2. **Persist `shutdown` mode in kernel sysfs:**
   ```bash
   sudo tee /etc/tmpfiles.d/hibernatemode.conf << 'EOF'
   w /sys/power/disk - - - - shutdown
   EOF
   ```

---

### Step 3: Fix KWin Wayland Display Resume

1. **User session environment variable:**
   ```bash
   mkdir -p ~/.config/environment.d
   echo "KWIN_DRM_NO_AMS=0" >> ~/.config/environment.d/kwin.conf
   ```

2. **Systemd service drop-ins for sleep services:**
   ```bash
   sudo mkdir -p /etc/systemd/system/systemd-hibernate.service.d
   sudo tee /etc/systemd/system/systemd-hibernate.service.d/kwin-fix.conf << 'EOF'
   [Service]
   Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0
   EOF

   # Link to suspend service
   sudo mkdir -p /etc/systemd/system/systemd-suspend.service.d
   sudo ln -sf /etc/systemd/system/systemd-hibernate.service.d/kwin-fix.conf /etc/systemd/system/systemd-suspend.service.d/kwin-fix.conf
   ```

3. **Mask Plymouth sleep services:**
   ```bash
   sudo systemctl mask plymouth-hibernate.service \
                       plymouth-suspend.service \
                       plymouth-start.service 2>/dev/null || true
   ```

---

### Step 4: Install the Hardware-Aware Lid Runner

Systemd's internal `suspend-then-hibernate` uses a 0ms `timerfd` poll upon wake, causing it to misidentify timer expirations as user activity on Intel Arrow Lake. 

The custom runner resolves this by evaluating actual elapsed time, providing a 3-second PCIe settle delay, and disabling broken Tongfang ACPI GPE interrupts:

1. **Create `/usr/local/bin/suspend-then-hibernate-runner`:**
   ```bash
   sudo tee /usr/local/bin/suspend-then-hibernate-runner << 'EOF'
   #!/usr/bin/env bash

   # 1. Read configured HibernateDelaySec (defaults to 15min)
   CONF_DELAY=$(grep -E '^HibernateDelaySec=' /etc/systemd/sleep.conf.d/*.conf 2>/dev/null | tail -n 1 | cut -d= -f2 | tr -d ' ')
   CONF_DELAY=${CONF_DELAY:-15min}

   case "$CONF_DELAY" in
       *s) SECS="${CONF_DELAY%s}" ;;
       *min|*m) SECS=$(( ${CONF_DELAY%m*} * 60 )) ;;
       *h) SECS=$(( ${CONF_DELAY%h} * 3600 )) ;;
       *) SECS="$CONF_DELAY" ;;
   esac

   # 2. Check local vs UTC RTC
   RTC_OPTS=""
   if timedatectl 2>/dev/null | grep -qi "RTC in local TZ: yes"; then
       RTC_OPTS="-l"
   fi

   # 3. Disable broken GPEs before sleeping
   echo disable > /sys/firmware/acpi/interrupts/gpe6B 2>/dev/null || true
   echo disable > /sys/firmware/acpi/interrupts/gpe6E 2>/dev/null || true

   echo "[*] suspend-then-hibernate: Delay set to ${SECS}s. Arming RTC wake alarm..."
   rtcwake $RTC_OPTS -m no -s "$SECS"

   START_TIME=$(date +%s)

   # 4. Suspend to RAM
   /usr/lib/systemd/systemd-sleep suspend

   END_TIME=$(date +%s)
   ELAPSED=$(( END_TIME - START_TIME ))
   THRESHOLD=$(( SECS - 5 ))

   echo "[*] System woke up. Elapsed sleep duration: ${ELAPSED}s (Target: ${SECS}s)"

   # 5. Check physical lid state
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

   # 6. Evaluation Logic:
   if [ "$ELAPSED" -ge "$THRESHOLD" ] || [ "$LID_CLOSED" = "true" ]; then
       echo "[!] Target reached or lid closed. Allowing 3s for bus events to settle..."
       sleep 3

       # Clear GPE interrupts again in case wake-up armed them
       echo disable > /sys/firmware/acpi/interrupts/gpe6B 2>/dev/null || true
       echo disable > /sys/firmware/acpi/interrupts/gpe6E 2>/dev/null || true

       echo "[!] Transitioning to 0-Watt Hibernation..."
       /usr/lib/systemd/systemd-sleep hibernate
   else
       echo "[✓] System was woken by user opening the lid. Returning to desktop."
   fi
   EOF
   sudo chmod +x /usr/local/bin/suspend-then-hibernate-runner
   ```

2. **Hook the runner into systemd:**
   ```bash
   sudo mkdir -p /etc/systemd/system/systemd-suspend-then-hibernate.service.d
   sudo tee /etc/systemd/system/systemd-suspend-then-hibernate.service.d/override-runner.conf << 'EOF'
   [Service]
   ExecStart=
   ExecStart=/usr/local/bin/suspend-then-hibernate-runner
   EOF

   sudo systemctl daemon-reload
   ```

---

### Step 5: Universal AC & Lid Suspend Redirect

Redirect standard suspend requests to `suspend-then-hibernate` so closing the lid while plugged in also triggers the automated handoff:

```bash
sudo mkdir -p /etc/systemd/system/systemd-suspend.service.d
sudo tee /etc/systemd/system/systemd-suspend.service.d/override-to-suspend-then-hibernate.conf << 'EOF'
[Service]
Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0
ExecStart=
ExecStart=/usr/local/bin/suspend-then-hibernate-runner
EOF

# Logind configuration
sudo mkdir -p /etc/systemd/logind.conf.d
sudo tee /etc/systemd/logind.conf.d/lid-hibernate.conf << 'EOF'
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend-then-hibernate
HandleLidSwitchDocked=ignore
EOF

sudo systemctl daemon-reload
```

---

## 4. Verification

### Fast 30-Second Verification Test
1. Set the delay to 30 seconds:
   ```bash
   sudo sed -i 's/HibernateDelaySec=.*/HibernateDelaySec=30s/' /etc/systemd/sleep.conf.d/50-sleep-fix.conf
   sudo systemctl daemon-reload
   ```
2. Close the lid or run:
   ```bash
   sudo systemctl suspend-then-hibernate
   ```
3. Observe:
   * **0s – 30s:** Suspended to RAM (LED pulses slowly).
   * **At 30s:** RTC wakes system silently. The runner settles the bus and triggers hibernation.
   * **At ~40s:** Power LED turns **completely OFF** (0.0 Watts).
4. Press power button $\rightarrow$ session restores in ~8 seconds.
5. Revert back to 15 minutes:
   ```bash
   sudo sed -i 's/HibernateDelaySec=.*/HibernateDelaySec=15min/' /etc/systemd/sleep.conf.d/50-sleep-fix.conf
   sudo systemctl daemon-reload
   ```
