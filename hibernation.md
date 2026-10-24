Congratulations! Reaching a working hibernation and resume cycle on an Intel Core Ultra (Meteor Lake) laptop with hybrid graphics is a significant milestone.

Below is how to inspect your logs to confirm everything ran cleanly, followed by a complete, self-contained Markdown (`.md`) guide documenting every step of the setup.

---

### Part 1: How to View the Successful Hibernation & Resume Logs

Since your system successfully woke up into the current boot (`boot 0`), all the details about saving the snapshot, writing it to swap, and restoring memory are recorded in the active journal.

#### 1. See the Kernel Hibernation & Resume Lifecycle
Run this to see the full timeline (allocating image, writing speed, restoring memory, waking devices):
```bash
journalctl -k -b 0 | grep -E -i "(PM:.*hibernation|image|restored|pages)" --no-pager
```
*What you will see:*
* How many gigabytes were compressed and written to `/dev/nvme0n1p7`.
* The exact write speed (e.g., `~650 MB/s`).
* `PM: hibernation: Hibernation image restored successfully.`
* `PM: hibernation: Basic memory bitmaps freed.`

#### 2. Inspect the Systemd Hibernate Service
To see systemd's perspective, including execution time and unit freezing:
```bash
systemctl status systemd-hibernate.service --no-pager
```
Or view its service journal:
```bash
journalctl -b 0 -u systemd-hibernate.service --no-pager
```

#### 3. View Driver Resume Timings
To see how fast each piece of hardware (Intel Arc GPU, NVMe drive, Wi-Fi) woke up:
```bash
journalctl -k -b 0 | grep -E -i "(calling.*restore|restore of devices complete)" | tail -n 40
```

---

### Part 2: Complete Hibernation Configuration Guide

Save the text below as `fedora-meteorlake-hibernation.md`. It covers the full architecture, root causes, and all commands to reproduce the setup from scratch.

```markdown
# Complete Guide: Enabling Hibernation on Fedora (Intel Meteor Lake + Hybrid NVIDIA)

This guide documents the full setup required to enable reliable, fast hibernation and resume on laptops powered by **Intel Core Ultra (Meteor Lake)** processors with **Intel Arc Graphics** and hybrid **NVIDIA dGPUs**, running **Fedora**, **KDE Plasma 6 (Wayland)**, and **systemd**.

---

## 1. Hardware & System Baseline

* **CPU / iGPU:** Intel Core Ultra (Meteor Lake - Device ID `7d67`, e.g., Ultra 7 / Ultra 9)
* **dGPU:** NVIDIA RTX Mobile (handled as secondary / idle for everyday use)
* **OS:** Fedora Linux (Kernel 6.x / 7.x+)
* **Desktop:** KDE Plasma (Wayland)
* **Swap Target:** Physical NVMe partition (e.g., `/dev/nvme0n1p7`, minimum size = RAM size)

---

## 2. Root Causes Solved by This Configuration

1. **ACPI S4 Firmware Lockup:** Most modern laptop UEFI firmwares have broken or unsupported ACPI S4 (`platform`) implementations. Waking or sleeping in `platform` mode hangs the laptop with a black screen and spinning fans. **Solution:** Enforce OS-level `HibernateMode=shutdown`.
2. **NVIDIA Driver Shutdown Deadlock:** During system shutdown, proprietary NVIDIA modules deadlock in `nv_drm_dev_unload` while trying to communicate with SBIOS. **Solution:** Blacklist NVIDIA modules for daily Intel-only operation.
3. **Meteor Lake Display Link Bug (Black Screen):** Intel's Panel Self Refresh 2 (PSR2) on the Meteor Lake CX0 DisplayPort/eDP transceiver fails clock re-synchronization on cold wake. **Solution:** `i915.enable_psr=0` and `i915.fastboot=0`.
4. **Device Resume Race Condition:** Parallel driver wake-up causes the display pipe to initialize before the PCIe bridge. **Solution:** `pm_async=0`.
5. **KWin Wayland Lit Black Screen:** In KDE Plasma Wayland, freezing user sessions via systemd's cgroups freezer leaves KWin's DRM master release in a deadlocked state upon wake, illuminating the backlight with no framebuffer. **Solution:** Set `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0` and `KWIN_DRM_NO_AMS=0`.

---

## 3. Step-by-Step Configuration

### Step 1: Configure Swap and Kernel Resume UUID

Find your swap partition's filesystem UUID:
```bash
lsblk -f
```
*(Locate your swap partition, e.g., `nvme0n1p7`, and copy its UUID).*

Ensure `/etc/fstab` references this UUID:
```text
UUID=YOUR_SWAP_UUID none swap defaults 0 0
```

Add the resume parameter to the kernel command line:
```bash
sudo grubby --update-kernel=ALL --args="resume=UUID=YOUR_SWAP_UUID"
```

---

### Step 2: Apply Meteor Lake & Power Management Kernel Arguments

Run `grubby` to set the required display and timing flags:

```bash
sudo grubby --update-kernel=ALL --args="i915.enable_psr=0 i915.fastboot=0 pm_async=0"
```

* **`i915.enable_psr=0`**: Disables Panel Self Refresh, allowing the display transceiver to wake from cold state.
* **`i915.fastboot=0`**: Forces a clean re-initialization of display mode timings on resume.
* **`pm_async=0`**: Forces synchronous device restoration to prevent PCIe bridge race conditions.

---

### Step 3: Blacklist NVIDIA Drivers (For Daily Intel-Only Operation)

To prevent the NVIDIA kernel driver from loading and deadlocking PCI shutdown:

```bash
sudo grubby --update-kernel=ALL --args="rd.driver.blacklist=nouveau,nova_core,nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm modprobe.blacklist=nouveau,nova_core,nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm"
```

*(This leaves the dGPU in low-power idle without software locks, maximizing battery life on Intel Arc).*

---

### Step 4: Configure Systemd Hibernation Mode (`shutdown`)

Force systemd to turn off power via standard hardware shutdown rather than calling buggy ACPI S4 firmware methods:

```bash
sudo mkdir -p /etc/systemd/sleep.conf.d
sudo tee /etc/systemd/sleep.conf.d/hibernatemode.conf << 'EOF'
[Sleep]
AllowHibernation=yes
HibernateMode=shutdown
EOF
```

---

### Step 5: Fix KDE Plasma Wayland / KWin Display Wake

#### A. Session Environment Flag
Create an environment override to prevent KWin from losing its DRM surface state:
```bash
mkdir -p ~/.config/environment.d
echo "KWIN_DRM_NO_AMS=0" >> ~/.config/environment.d/kwin.conf
```

#### B. Systemd Hibernate Service Drop-In
Prevent systemd from cgroup-freezing Wayland user sessions before the GPU pipe is ready:
```bash
sudo mkdir -p /etc/systemd/system/systemd-hibernate.service.d
sudo tee /etc/systemd/system/systemd-hibernate.service.d/kwin-fix.conf << 'EOF'
[Service]
Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0
EOF
sudo systemctl daemon-reload
```

---

### Step 6: Verify Dracut Initramfs Includes the Resume Module

Check that the Dracut initramfs includes the resume generator:
```bash
lsinitrd | grep systemd-hibernate-resume
```
If missing, regenerate your initramfs:
```bash
sudo dracut -f --add "resume"
```

---

## 4. Testing & Verification

1. **Reboot the system to apply all arguments:**
   ```bash
   sudo reboot
   ```

2. **Verify active kernel command line:**
   ```bash
   cat /proc/cmdline
   ```
   Ensure `resume=UUID=...`, `i915.enable_psr=0`, `i915.fastboot=0`, `pm_async=0`, and the blacklists are present.

3. **Trigger hibernation:**
   ```bash
   sudo systemctl hibernate
   ```

4. **Wake the system:**
   Press the power button. The bootloader will restore your RAM session in under 10 seconds, and the screen will illuminate with your open windows intact.

---

## 5. Maintenance & Useful Commands

| Action | Command |
| :--- | :--- |
| **Trigger Hibernation** | `sudo systemctl hibernate` |
| **Check Hibernation Service Log** | `journalctl -b 0 -u systemd-hibernate.service` |
| **Verify Image Restore Speed** | `journalctl -k -b 0 \| grep "PM: hibernation"` |
| **Check Active Sleep Mode** | `cat /sys/power/disk` *(returns `shutdown` during sleep)* |
| **Check Resume Partition ID** | `cat /sys/power/resume` |
```