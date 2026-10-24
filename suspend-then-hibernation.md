
# Comprehensive Guide: Suspend-Then-Hibernate on Fedora
### Intel Core Ultra (Meteor Lake) + Hybrid NVIDIA + KDE Plasma (Wayland)

---

## 1. Overview & Target Architecture

This guide provides a complete, robust configuration for **Suspend-then-Hibernate** on hybrid laptops. When the lid is closed or sleep is triggered:
1. The laptop immediately enters **Suspend to RAM** (`s2idle` / sleep) with the power LED pulsing slowly.
2. An internal RTC hardware timer waits for a configurable period (e.g., **15 minutes**).
3. If not opened, the system wakes silently, writes the compressed RAM snapshot to the NVMe swap partition at >600 MB/s, and cuts power completely (**0-Watt Hibernation**).
4. Pressing the power button restores your desktop, apps, and window layout in ~8 seconds.
5. An on-demand toggle allows the NVIDIA dGPU to run at 100% performance for gaming without breaking power management.

### System Specifications
* **CPU / iGPU:** Intel Core Ultra (Meteor Lake, device ID `7d67`) with Intel Arc Graphics
* **dGPU:** NVIDIA RTX Mobile (Hybrid architecture)
* **OS:** Fedora Linux (Kernel 6.x / 7.x+)
* **Desktop Environment:** KDE Plasma 6 (Wayland)
* **Swap Device:** Physical NVMe partition (minimum size ≥ RAM size)

---

## 2. Technical Root Causes Solved

| Problem Encountered | Root Cause | Implemented Solution |
| :--- | :--- | :--- |
| **ACPI S4 Firmware Hang** | Motherboard UEFI BIOS locks up when calling ACPI S4 (`platform`) sleep. | Enforce OS-level `HibernateMode=shutdown`. |
| **NVIDIA Teardown Deadlock** | NVIDIA driver deadlocks in `nv_drm_dev_unload` when PCI shutdown is called. | Blacklist NVIDIA modules for daily use; load on demand for gaming. |
| **Display Wake Failure** | Meteor Lake eDP CX0 transceiver fails link training on cold wake (PSR2 bug). | Kernel parameter `i915.enable_psr=0` and `i915.fastboot=0`. |
| **Wake Race Condition** | Parallel asynchronous driver resume causes display pipe initialization timeout. | Kernel parameter `pm_async=0`. |
| **KWin Lit Black Screen** | Systemd cgroup freezer freezes `user.slice`, deadlocking KWin's DRM master release. | Set `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0` on sleep services. |

---

## 3. Step-by-Step Configuration

### Step 1: Identify Swap UUID & Set Kernel Resume Parameter

1. Find the UUID of your physical swap partition:
   ```bash
   lsblk -f
   ```
   *(Locate your swap partition, e.g., `/dev/nvme0n1p7`, and copy its UUID).*

2. Verify that `/etc/fstab` uses the same UUID:
   ```text
   UUID=YOUR_SWAP_UUID none swap defaults 0 0
   ```

3. Add the resume target to your kernel command line using `grubby`:
   ```bash
   sudo grubby --update-kernel=ALL --args="resume=UUID=YOUR_SWAP_UUID"
   ```

---

### Step 2: Configure Kernel Display & Power Parameters

Apply the parameters required for Intel Arc Graphics (Meteor Lake) and synchronous driver restoration:

```bash
sudo grubby --update-kernel=ALL --args="i915.enable_psr=0 i915.fastboot=0 pm_async=0"
```

* `i915.enable_psr=0`: Disables Panel Self Refresh to ensure the display transceiver wakes up reliably.
* `i915.fastboot=0`: Forces proper display pipe mode retraining upon resume.
* `pm_async=0`: Forces synchronous (ordered) device wake-up to prevent PCIe race conditions.

---

### Step 3: Blacklist NVIDIA Modules on Boot (Intel Daily Mode)

Ensure the proprietary NVIDIA driver does not auto-load on boot, keeping the hardware in a clean, low-power state:

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

Also add kernel-level blacklisting arguments:
```bash
sudo grubby --update-kernel=ALL --args="rd.driver.blacklist=nouveau,nova_core,nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm modprobe.blacklist=nouveau,nova_core,nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm"
```

---

### Step 4: Configure `systemd` Suspend-Then-Hibernate

1. Create the sleep configuration drop-in:
   ```bash
   sudo mkdir -p /etc/systemd/sleep.conf.d
   sudo tee /etc/systemd/sleep.conf.d/suspend-then-hibernate.conf << 'EOF'
   [Sleep]
   AllowSuspend=yes
   AllowHibernation=yes
   AllowSuspendThenHibernate=yes
   HibernateMode=shutdown
   HibernateDelaySec=15min
   EOF
   ```
   * `HibernateMode=shutdown`: Bypasses ACPI S4 and uses standard hardware shutdown.
   * `HibernateDelaySec=15min`: Sets the sleep duration to 15 minutes before triggering hibernation.

---

### Step 5: Fix KDE Plasma Wayland / KWin Display Wake

To eliminate the "illuminated black screen" bug caused by cgroup user session freezing:

1. **KWin session environment:**
   ```bash
   mkdir -p ~/.config/environment.d
   echo "KWIN_DRM_NO_AMS=0" >> ~/.config/environment.d/kwin.conf
   ```

2. **Systemd service drop-ins for both sleep services:**
   ```bash
   # Hibernate service drop-in
   sudo mkdir -p /etc/systemd/system/systemd-hibernate.service.d
   sudo tee /etc/systemd/system/systemd-hibernate.service.d/kwin-fix.conf << 'EOF'
   [Service]
   Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0
   EOF

   # Suspend-then-hibernate service drop-in (shares the same rule)
   sudo mkdir -p /etc/systemd/system/systemd-suspend-then-hibernate.service.d
   sudo ln -sf /etc/systemd/system/systemd-hibernate.service.d/kwin-fix.conf /etc/systemd/system/systemd-suspend-then-hibernate.service.d/kwin-fix.conf

   sudo systemctl daemon-reload
   ```

---

### Step 6: Configure Lid Switch in `systemd-logind` & KDE

1. Tell `logind` to invoke `suspend-then-hibernate` on lid close:
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
   * Go to **System Settings** → **Power Management** → **Energy Saving**.
   * Under both **On Battery** and **On AC Power**:
     * Set **When laptop lid is closed** to **Sleep** (or **Sleep then Hibernate** if explicitly present).
   * Click **Apply**.

---

### Step 7: Verify Dracut Initramfs

Ensure Dracut includes the resume tool in early boot:
```bash
lsinitrd | grep systemd-hibernate-resume
```
If missing, rebuild the initramfs:
```bash
sudo dracut -f --add "resume"
```

---

## 4. On-Demand NVIDIA Gaming Toggle

Use these scripts to load the NVIDIA driver on demand at 100% performance, while automatically protecting your system from accidental hibernation lockups.

### Create `/usr/local/bin/game-on`:
```bash
sudo tee /usr/local/bin/game-on << 'EOF'
#!/usr/bin/env bash
echo "Activating NVIDIA dGPU..."
sudo modprobe nvidia
sudo modprobe nvidia_modeset
sudo modprobe nvidia_uvm
sudo modprobe nvidia_drm
sudo systemctl start nvidia-powerd 2>/dev/null

# Safeguard: Mask sleep/hibernate while NVIDIA is loaded to prevent driver teardown freezes
sudo systemctl mask systemd-hibernate.service systemd-suspend-then-hibernate.service 2>/dev/null

echo "=================================================="
echo " NVIDIA IS ACTIVE (100% Full Hardware Performance)"
echo " Sleep & Hibernation are locked for system safety."
echo "=================================================="
echo "Launch games via Steam or right-click 'Run with Dedicated GPU'."
EOF
sudo chmod +x /usr/local/bin/game-on
```

### Create `/usr/local/bin/game-off`:
```bash
sudo tee /usr/local/bin/game-off << 'EOF'
#!/usr/bin/env bash
echo "Deactivating NVIDIA dGPU..."
sudo systemctl stop nvidia-powerd 2>/dev/null

# Check if any process is actively using the GPU
if sudo fuser /dev/nvidia* 2>/dev/null; then
    echo "Warning: A game or application is still using the NVIDIA GPU:"
    sudo fuser -v /dev/nvidia* 2>/dev/null
    echo "Please close the application first, then re-run game-off."
    exit 1
fi

sudo modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia

if lsmod | grep -q nvidia; then
    echo "Error: Could not unload NVIDIA modules. Check running background tasks."
else
    # Re-enable sleep & hibernation
    sudo systemctl unmask systemd-hibernate.service systemd-suspend-then-hibernate.service 2>/dev/null
    echo "=================================================="
    echo " NVIDIA UNLOADED - System back on Intel-only mode."
    echo " Sleep and Hibernation are UNLOCKED and ready."
    echo "=================================================="
fi
EOF
sudo chmod +x /usr/local/bin/game-off
```

---

## 5. Verification & Testing

### Fast 30-Second Verification Test
To confirm the entire automated handoff works without waiting 15 minutes:

1. Temporarily set the timer to 30 seconds:
   ```bash
   sudo sed -i 's/HibernateDelaySec=.*/HibernateDelaySec=30s/' /etc/systemd/sleep.conf.d/suspend-then-hibernate.conf
   ```
2. Trigger the cycle:
   ```bash
   sudo systemctl suspend-then-hibernate
   ```
3. **Timeline:**
   * **0s – 30s:** System suspends to RAM (power LED pulses).
   * **At 30s:** RTC alarm fires. System wakes silently and writes the snapshot to disk (~8 seconds).
   * **At ~40s:** Power LED turns completely **OFF** (Hibernation).
4. Press the **Power button** to verify that your session restores cleanly.
5. Revert the timer back to 15 minutes:
   ```bash
   sudo sed -i 's/HibernateDelaySec=.*/HibernateDelaySec=15min/' /etc/systemd/sleep.conf.d/suspend-then-hibernate.conf
   ```

---

## 6. Daily Usage & Useful Commands

| Action | Command / Procedure |
| :--- | :--- |
| **Normal Sleep & Hibernate** | Close the laptop lid. Wakes instantly if opened within 15 mins; powers off to swap if left longer. |
| **Manual Direct Hibernate** | `sudo systemctl hibernate` |
| **Start Gaming Mode** | Run `game-on` in terminal. *(Hibernation safely blocked).* |
| **End Gaming Mode** | Close games and run `game-off`. *(Hibernation unblocked).* |
| **Inspect Sleep/Hibernate Logs** | `journalctl -b 0 -u systemd-suspend-then-hibernate.service` |
| **Inspect Kernel Memory Timings** | `journalctl -k -b 0 --no-pager \| grep -E "(PM:.*hibernation\|image\|restored)"` |
| **Verify NVIDIA State** | `lsmod \| grep nvidia` *(Should return empty when not gaming)* |
