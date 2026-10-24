
# Comprehensive Guide: Suspend-Then-Hibernate on Fedora (KDE Plasma 6 Wayland)
### Intel Core Ultra 9 275HX (Arrow Lake / Meteor Lake Arc) + NVIDIA RTX Mobile

---

## 1. Overview & Target Behavior

This guide documents the complete, battle-tested setup required to achieve reliable **Suspend-then-Hibernate** on hybrid laptops running **Fedora**, **KDE Plasma 6 (Wayland)**, and **systemd**.

### How the System Operates:
1. **Immediate Sleep:** Closing the laptop lid (or pressing Sleep, whether on battery or plugged into the charger) puts the laptop into **Suspend to RAM** (`s2idle`) instantly. The power LED pulses slowly.
2. **Automated 15-Minute Handoff:** An internal RTC hardware alarm waits for **15 minutes**.
3. **0-Watt Power Cut:** If the lid is not opened within 15 minutes, the system wakes silently without illuminating the screen, compresses RAM (~7–8 GB) to the NVMe swap partition at >600 MB/s, and cuts power completely (**true 0.0W Hibernation**; power LED turns off).
4. **Clean Wake-up:** Pressing the power button restores your desktop session, open applications, and window arrangement in ~8 seconds without black screens or compositor freezes.
5. **On-Demand Gaming (`game-on` / `game-off`):** When you want to game on the dedicated NVIDIA GPU, a single command switches EnvyControl and automatically locks hibernation so driver teardown crashes can never occur.

---

## 2. Tested Hardware Baseline

| Component | Tested Specification |
| :--- | :--- |
| **Laptop Chassis** | PCSpecialist Ionico II 16 (Uniwill GM6HG / Tongfang) |
| **Processor** | Intel Core Ultra 9 275HX (24 Cores / 24 Threads) @ 5.40 GHz |
| **Integrated GPU** | Intel Arc Graphics / Xe-LPG (Device ID `7d67`) |
| **Discrete GPU** | NVIDIA GeForce RTX 5060 Max-Q / Mobile |
| **RAM** | 64 GB DDR5 |
| **Swap Target** | 66.4 GB Dedicated NVMe Partition (`/dev/nvme0n1p7`) |
| **Display** | 16" 2560x1600 (16:10 QHD+), 60 Hz / 240 Hz |
| **Operating System** | Fedora Linux 44 (x86_64) • Kernel 7.2.x+ |
| **Desktop Environment** | KDE Plasma 6.7+ on KWin (Wayland) |

---

## 3. Technical Problems & Root Causes Solved

| Problem Encountered | Root Cause | Implemented Solution |
| :--- | :--- | :--- |
| **ACPI S4 Firmware Hang** | Motherboard UEFI BIOS locks up when calling ACPI S4 (`platform`) sleep. | Enforce OS-level `HibernateMode=shutdown`. |
| **NVIDIA Teardown Deadlock** | NVIDIA driver deadlocks inside `nv_drm_dev_unload` when PCI shutdown is called during hibernate. | Detach dGPU at PCIe level (`remove=1`) via EnvyControl `integrated` mode for daily use. |
| **Display Wake Failure (Dark Screen)** | Meteor Lake eDP CX0 transceiver fails link clock re-synchronization on cold wake (PSR2 bug). | Kernel flags: `i915.enable_psr=0` and `i915.fastboot=0`. |
| **Wake Race Condition** | Parallel asynchronous driver resume causes display pipe initialization timeout. | Kernel flag: `pm_async=0`. |
| **Lit Black Screen on Wake** | Systemd cgroup freezer freezes `user.slice`, deadlocking KWin's DRM master release upon wake. | Service drop-in: `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0` + `KWIN_DRM_NO_AMS=0`. |
| **Plugged-In Sleep Ignored** | Systemd suppresses hibernate on AC power; KDE sends plain `systemd-suspend.service` on AC. | `HibernateOnACPower=yes` + redirecting `systemd-suspend.service` to `suspend-then-hibernate`. |

---

## 4. Step-by-Step Configuration

### Step 1: Configure Swap Partition & Kernel Resume Target

Hibernating 64 GB of RAM requires a dedicated physical swap partition at least the size of your RAM (64 GB+).

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

3. Add the resume target, display transceiver fixes, and NVIDIA blacklists to your kernel command line using `grubby`:
   ```bash
   sudo grubby --update-kernel=ALL --args="resume=UUID=${SWAP_UUID} i915.enable_psr=0 i915.fastboot=0 pm_async=0 rd.driver.blacklist=nouveau,nova_core,nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm modprobe.blacklist=nouveau,nova_core,nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm"
   ```

---

### Step 2: Blacklist NVIDIA Kernel Modules for Daily Intel Mode

Prevent the proprietary NVIDIA modules from loading during boot:

```bash
sudo tee /etc/modprobe.d/nvidia-blacklist.conf << 'EOF'
blacklist nouveau
blacklist nova_core
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
EOF
```

---

### Step 3: Configure Systemd Sleep (15-Minute Timer & AC Support)

Create the drop-in configuration for `systemd`:

```bash
sudo mkdir -p /etc/systemd/sleep.conf.d
sudo tee /etc/systemd/sleep.conf.d/suspend-then-hibernate.conf << 'EOF'
[Sleep]
AllowSuspend=yes
AllowHibernation=yes
AllowSuspendThenHibernate=yes
HibernateMode=shutdown
HibernateDelaySec=15min
HibernateOnACPower=yes
EOF
```

* `HibernateMode=shutdown`: Cuts power at the OS level, completely bypassing buggy motherboard ACPI S4 BIOS calls.
* `HibernateDelaySec=15min`: Sets the sleep duration to 15 minutes before the RTC alarm wakes the system to hibernate.
* `HibernateOnACPower=yes`: Ensures the laptop hibernates after 15 minutes even when connected to the charger.

---

### Step 4: Fix KWin Wayland Display Wake & Cgroup Freezer

To eliminate the "illuminated black screen" bug where KWin's DRM master release deadlocks on wake:

1. **User session environment variable:**
   ```bash
   mkdir -p ~/.config/environment.d
   echo "KWIN_DRM_NO_AMS=0" >> ~/.config/environment.d/kwin.conf
   ```

2. **Systemd service drop-ins for all sleep targets:**
   ```bash
   # 1. Hibernate service drop-in
   sudo mkdir -p /etc/systemd/system/systemd-hibernate.service.d
   sudo tee /etc/systemd/system/systemd-hibernate.service.d/kwin-fix.conf << 'EOF'
   [Service]
   Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0
   EOF

   # 2. Suspend-then-hibernate service drop-in
   sudo mkdir -p /etc/systemd/system/systemd-suspend-then-hibernate.service.d
   sudo ln -sf /etc/systemd/system/systemd-hibernate.service.d/kwin-fix.conf /etc/systemd/system/systemd-suspend-then-hibernate.service.d/kwin-fix.conf
   ```

---

### Step 5: Universal AC & Lid Suspend Redirect

Because KDE Plasma's "On AC Power" profile and certain menu actions trigger standard `systemd-suspend.service` (which ignores hibernation), we redirect all plain suspend requests to `suspend-then-hibernate`:

```bash
sudo mkdir -p /etc/systemd/system/systemd-suspend.service.d
sudo tee /etc/systemd/system/systemd-suspend.service.d/override-to-suspend-then-hibernate.conf << 'EOF'
[Service]
Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0
ExecStart=
ExecStart=/usr/lib/systemd/systemd-sleep suspend-then-hibernate
EOF

sudo systemctl daemon-reload
```

---

### Step 6: Configure Lid Switch in `systemd-logind` & KDE

1. Tell `systemd-logind` to invoke `suspend-then-hibernate` on lid close:
   ```bash
   sudo mkdir -p /etc/systemd/logind.conf.d
   sudo tee /etc/systemd/logind.conf.d/lid-hibernate.conf << 'EOF'
   [Login]
   HandleLidSwitch=suspend-then-hibernate
   HandleLidSwitchExternalPower=suspend-then-hibernate
   HandleLidSwitchDocked=ignore
   EOF
   ```

2. **KDE Plasma System Settings:**
   * Open **System Settings** → **Power Management** (or **Energy Saving**).
   * Under both **On Battery** and **On AC Power**:
     * Set **When laptop lid is closed** to **Sleep** (with our redirect in Step 5, this automatically executes `suspend-then-hibernate`).
   * Click **Apply**.

---

### Step 7: Verify Dracut Initramfs

Ensure the Dracut initramfs includes the resume generator:
```bash
lsinitrd | grep systemd-hibernate-resume
```
If missing, regenerate the initramfs:
```bash
sudo dracut -f --add "resume"
```

---

## 5. Dual-Mode Gaming Toggle (EnvyControl + Safety Lock)

Because the proprietary NVIDIA driver deadlocks on hibernation power-off, we keep the dGPU detached on everyday boots (`integrated` mode) and use dedicated wrapper scripts to switch modes safely.

### 1. `/usr/local/bin/game-on` (Enters Gaming Mode & Locks Hibernation)
```bash
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

# 2. SAFETY: Lock hibernation so you cannot accidentally freeze while gaming
sudo systemctl mask systemd-hibernate.service systemd-suspend-then-hibernate.service 2>/dev/null

echo ""
echo "EnvyControl configured for NVIDIA gaming."
echo "Hibernation has been SAFELY LOCKED for this session."
echo ""
read -p "Reboot now to enter Gaming Mode? [Y/n] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
    sudo reboot
fi
EOF
sudo chmod +x /usr/local/bin/game-on
```

### 2. `/usr/local/bin/game-off` (Returns to Intel Mode & Unlocks Hibernation)
```bash
sudo tee /usr/local/bin/game-off << 'EOF'
#!/usr/bin/env bash
set -e

CURRENT=$(envycontrol -q 2>/dev/null || echo "unknown")

if [ "$CURRENT" = "integrated" ]; then
    echo "You are already in Intel-Only (0W Hibernation) mode!"
    exit 0
fi

echo "=================================================="
echo " Returning to EVERYDAY MODE (Intel-Only 0W)"
echo "=================================================="

# 1. Switch EnvyControl back to integrated (cuts NVIDIA PCIe power)
sudo envycontrol -s integrated

# 2. RESTORE: Unlock hibernation and suspend-then-hibernate
sudo systemctl unmask systemd-hibernate.service systemd-suspend-then-hibernate.service 2>/dev/null

echo ""
echo "NVIDIA dGPU will be detached on boot (True 0-Watt idle)."
echo "Hibernation & Suspend-then-Hibernate are UNLOCKED."
echo ""
read -p "Reboot now to return to Intel/Hibernation Mode? [Y/n] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
    sudo reboot
fi
EOF
sudo chmod +x /usr/local/bin/game-off
```

---

## 6. Fast 30-Second Verification Test

You do not need to wait 15 minutes to verify that the automated handoff works.

1. **Temporarily reduce the timer to 30 seconds:**
   ```bash
   sudo sed -i 's/HibernateDelaySec=.*/HibernateDelaySec=30s/' /etc/systemd/sleep.conf.d/suspend-then-hibernate.conf
   sudo systemctl daemon-reload
   ```

2. **Trigger the cycle:**
   ```bash
   sudo systemctl suspend-then-hibernate
   ```
   *(Or close your laptop lid).*

3. **Observe the hardware timeline:**
   * **0s – 30s (Suspend Phase):** The screen turns off immediately. The power LED **pulses slowly** (system is suspended to RAM).
   * **At 30s (Transition Phase):** The internal RTC hardware alarm fires. The system wakes silently (display stays dark) and writes ~7.5 GB from RAM to the NVMe swap partition at ~650 MB/s (~8 seconds).
   * **At ~40s (Hibernation Phase):** The power LED turns **completely OFF**. Power draw drops to **0.0 Watts**.

4. **Wake up the laptop:**
   Press the **Power button**. The bootloader detects the hibernation snapshot, restores your session in ~8 seconds, and your desktop appears with all windows intact.

5. **Revert the delay back to 15 minutes:**
   ```bash
   sudo sed -i 's/HibernateDelaySec=.*/HibernateDelaySec=15min/' /etc/systemd/sleep.conf.d/suspend-then-hibernate.conf
   sudo systemctl daemon-reload
   ```

---

## 7. Verification & Diagnostic Commands

| Check / Action | Command | Expected Output in Everyday Mode |
| :--- | :--- | :--- |
| **Inspect Last Sleep Transition** | `journalctl -b 0 -u systemd-suspend-then-hibernate.service` | Shows suspend, RTC wake, and handoff to hibernate |
| **Inspect Kernel Memory Timings** | `journalctl -k -b 0 --no-pager \| grep -E "(PM:.*hibernation\|image\|restored)"` | Shows compressed image restore speed (>3000 MB/s snapshot) |
| **Active GPU Mode** | `envycontrol -q` | `integrated` |
| **PCIe Power Status** | `lspci \| grep -i nvidia` | *(Empty / Nothing)* |
| **Hibernation Safety Lock** | `systemctl status systemd-hibernate.service` | `inactive (dead)` (or `masked` while gaming) |
| **Manual Direct Hibernate** | `sudo systemctl hibernate` | Powers off to swap immediately |
```