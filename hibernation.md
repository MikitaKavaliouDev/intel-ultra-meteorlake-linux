
### The Forensic Reality: Why Hibernation Kept Failing & How We Solved It

Your laptop is an **Intel Core Ultra 9 275HX (Arrow Lake-HX with Meteor Lake Arc Graphics architecture, device ID `7d67`) + NVIDIA RTX Mobile**, running **Fedora 44 / KDE Plasma 6 (Wayland)**. 

Getting hibernation to work required solving **six separate, compounding failure points** across the UEFI firmware, the proprietary NVIDIA driver, the Intel display transceiver, systemd, and the KWin Wayland compositor:

```
[System Trigger: systemctl hibernate]
     │
     ├── 1. Swap Space Sizing ───────────► 64 GB RAM needed >64 GB physical NVMe swap (Fixed: 66.4 GB partition)
     │
     ├── 2. Process & Driver Freezing ───► Verified safe with /sys/power/pm_test
     │
     ├── 3. Device Shutdown Freeze ──────► NVIDIA driver deadlocked inside nv_drm_dev_unload
     │                                     └── Fix: Detach card on boot via EnvyControl integrated (remove=1)
     │
     ├── 4. Power-Off Hang ──────────────► Motherboard UEFI firmware hung on ACPI S4 (platform) sleep
     │                                     └── Fix: Enforce OS-level HibernateMode=shutdown
     │
[Power Button Wake / Memory Restore]
     │
     ├── 5. Display Transceiver Desync ──► Intel Arc DisplayPort/eDP transceiver failed link re-training
     │                                     └── Fix: i915.enable_psr=0, i915.fastboot=0, pm_async=0
     │
     └── 6. "Lit Black Screen" Deadlock ─► Systemd cgroup freezer locked user.slice; KWin couldn't reacquire DRM master
                                           └── Fix: SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0 & KWIN_DRM_NO_AMS=0
```

---

### The 7 Layers We Fixed (The Real Story)

#### 1. The Swap Space & Code `-22` Demystified
* **The Symptom:** Boot logs repeatedly showed `PM: Image not found (code -22)`.
* **The Discovery:** Error code `-22` (`-EINVAL`) occurs on cold boot or after a failed wake because **the Linux kernel's very first action when reading swap is to invalidate the `SWSUSP` header**. It does this intentionally so that if wake-up fails, the machine will not get trapped in an infinite reboot loop.
* **The Sizing:** With 64 GB of physical RAM, allocating a dedicated **66.4 GB NVMe physical swap partition** (`/dev/nvme0n1p7`) ensured the compressed snapshot (7–8 GB) never hit `-ENOSPC` (error `-28`).

#### 2. The NVIDIA Driver Shutdown Deadlock
* **The Symptom:** Screen froze with scrolling text stopping right after:
  ```text
  [drm] [nvidia-drm] [GPU ID 0x00000200] Removing device
  [drm] [nvidia-drm] [GPU ID 0x00000200] Unloading driver
  ```
* **The Root Cause:** When the kernel initiated PCI device teardown during hibernation power-off, the proprietary NVIDIA module wedged in `nv_drm_dev_unload` while handshaking with SBIOS/ACPI. The CPU froze before it could issue the power-down command.
* **The Fix:** For everyday mode, we unbind and physically detach the NVIDIA card on boot using EnvyControl's `integrated` mode (`remove=1`) and kernel blacklisting. When the dGPU does not exist on the PCIe bus, the shutdown deadlock is physically impossible.

#### 3. The ACPI S4 Firmware Hang
* **The Symptom:** After image saving, the screen stayed black, power lights stayed on, and fans continued spinning indefinitely.
* **The Root Cause:** Modern Tongfang / Uniwill UEFI firmwares do not properly implement ACPI S4 (`platform`) sleep states.
* **The Fix:** In `/etc/systemd/sleep.conf.d/hibernatemode.conf`, we forced:
  ```ini
  [Sleep]
  HibernateMode=shutdown
  ```
  This tells the kernel to bypass ACPI S4 calls and cut power via a clean, hardware-level OS shutdown.

#### 4. The Display Transceiver Cold-Wake Hang (Dark Screen)
* **The Symptom:** The system powered off and woke up from the power button, but the display panel remained completely dead/unpowered.
* **The Root Cause:** On Intel Meteor Lake / Arrow Lake integrated graphics, the eDP CX0 DisplayPort transceiver fails clock link retraining on cold wake due to Panel Self Refresh 2 (PSR2) timing bugs. Parallel driver resume (`pm_async`) caused a race condition where the display pipe initialized before the PCIe root bridge was ready.
* **The Fix:** Three kernel flags applied via `grubby`:
  * `i915.enable_psr=0`: Completely disables Panel Self Refresh.
  * `i915.fastboot=0`: Forces the driver to re-train the display mode timings from scratch.
  * `pm_async=0`: Forces sequential, synchronous device resume.

#### 5. The "Lit Black Screen" Deadlock (KWin Wayland + Systemd Freezer)
* **The Symptom:** The screen woke up, **the backlight illuminated (screen was glowing black)**, but no login screen, cursor, or desktop appeared.
* **The Root Cause:** Backlight power was restored, but **KWin (Wayland compositor) failed to reacquire the DRM scanout buffer**. During `systemctl hibernate`, systemd freezes `user.slice` using the cgroup freezer. On wake, KWin was still frozen when the display pipe attempted atomic commit, deadlocking the compositor.
* **The Fix:**
  1. Set `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0` in a drop-in for `systemd-hibernate.service` and `systemd-suspend-then-hibernate.service` so KWin stays active to receive the DRM wake event.
  2. Set `KWIN_DRM_NO_AMS=0` in `~/.config/environment.d/kwin.conf` to keep the DRM surface state intact.

#### 6. The AC Power Suspend Redirect
* **The Symptom:** On battery, closing the lid transitioned to hibernate after 15 minutes. Plugged into the charger, the laptop stayed suspended forever and never hibernated.
* **The Root Cause:** Systemd suppresses hibernate on AC power by default, and KDE Plasma's "On AC Power" profile sends a plain D-Bus `suspend` request (`systemd-suspend.service`), which ignores all hibernation timers.
* **The Fix:** 
  1. Add `HibernateOnACPower=yes` in `sleep.conf.d`.
  2. Drop an override into `/etc/systemd/system/systemd-suspend.service.d/override-to-suspend-then-hibernate.conf` redirecting all suspend actions to `suspend-then-hibernate`.

#### 7. Systemd timerfd Race (Suspend-then-Hibernate Runner)
* **The Symptom:** The 15-minute RTC handoff fired early or was missed entirely on Intel Core Ultra / Arrow Lake platforms, causing random early hibernation or no hibernation at all.
* **The Root Cause:** Upstream `systemd-sleep suspend-then-hibernate` relies on an internal timerfd that races on modern Intel Core Ultra / Arrow Lake platforms.
* **The Fix:** Replace it with `/usr/local/bin/suspend-then-hibernate-runner`, which arms the RTC via `rtcwake` and uses elapsed-time evaluation (`$ELAPSED >= $THRESHOLD`) to decide whether to hibernate or return to the desktop.

---

### Step-by-Step Updates for Your Repository

To make your repository completely accurate, replace the content of your `hibernation.md` and update `README.md` with the verified production documentation below.

---

#### 1. Create / Update `hibernation.md` (Detailed Technical Architecture)

Save this as **`hibernation.md`**:

```markdown
# How Hibernation Was Solved: Technical Architecture & Root Causes
### PCSpecialist Ionico II 16 (Intel Core Ultra 9 275HX + NVIDIA RTX Mobile)

This document provides a technical post-mortem of why hibernation fails by default on modern Intel Core Ultra / Arrow Lake hybrid laptops, and the step-by-step configuration that solves it.

---

## The 7 Cascading Failure Points Solved

### 1. NVMe Swap Sizing & Kernel Image Invalidation (Code -22)
* **The Issue:** Kernel journals frequently report `PM: Image not found (code -22)` after failed wake attempts.
* **The Root Cause:** In Linux hibernation, error `-22` (`-EINVAL`) is normal on cold boot. The kernel's first action upon reading the hibernation snapshot is to invalidate the `SWSUSP` header on the swap partition so that if a driver hangs during wake, the laptop will not enter an infinite boot loop.
* **The Solution:** A dedicated **physical NVMe swap partition** formatted to **66.4 GB** (matching the 64 GB physical RAM + snapshot overhead), pointed to by `resume=UUID=<swap-uuid>`.

### 2. The NVIDIA Driver Shutdown Deadlock
* **The Issue:** Screen freezes right after writing memory to swap; text halts on:
  ```text
  [drm] [nvidia-drm] [GPU ID 0x00000200] Unloading driver
  ```
* **The Root Cause:** During hibernation power-off, the kernel calls `device_shutdown()`. The proprietary NVIDIA driver attempts to execute `nv_drm_dev_unload`, fails to communicate with SBIOS/ACPI, and locks up the CPU before it can issue the power-off command.
* **The Solution:** For everyday productivity, EnvyControl’s `integrated` mode physically unbinds the dGPU (`remove=1`) via udev. Because the card does not exist on the PCIe bus during normal boots, the teardown deadlock cannot occur.

### 3. ACPI S4 Firmware Lockup
* **The Issue:** The laptop saves the snapshot, but screen stays black, power LED stays illuminated, and fans spin indefinitely.
* **The Root Cause:** The Tongfang / Uniwill UEFI firmware does not properly handle the ACPI S4 (`platform`) sleep state.
* **The Solution:** Enforce standard hardware shutdown in `/etc/systemd/sleep.conf.d/hibernatemode.conf`:
  ```ini
  [Sleep]
  HibernateMode=shutdown
  ```

### 4. Intel Arc Transceiver Link Failure (Cold Wake Black Screen)
* **The Issue:** The laptop restores memory from swap, but the display panel remains completely pitch black (backlight off).
* **The Root Cause:** On Intel Meteor Lake / Arrow Lake integrated graphics (device ID `7d67`), Panel Self Refresh (PSR2) fails to re-synchronize display clock timings on cold wake. Asynchronous driver resume (`pm_async`) also causes the display pipe to initialize before the PCIe bridge is ready.
* **The Solution:** Apply kernel flags via `grubby`:
  ```bash
  sudo grubby --update-kernel=ALL --args="i915.enable_psr=0 i915.fastboot=0 pm_async=0"
  ```

### 5. KWin Wayland "Lit Black Screen" Deadlock
* **The Issue:** On resume, the screen backlight turns ON (screen is glowing black), but no cursor, desktop, or windows appear.
* **The Root Cause:** Backlight power works, but **KWin (KDE Plasma's Wayland compositor) fails to reacquire the DRM scanout buffer**. Systemd's cgroup freezer freezes `user.slice` during sleep; upon wake, KWin's DRM master release deadlocks before the display pipe can commit.
* **The Solution:**
  1. Add systemd service drop-in `/etc/systemd/system/systemd-hibernate.service.d/kwin-fix.conf`:
     ```ini
     [Service]
     Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0
     ```
  2. Add user session environment override `~/.config/environment.d/kwin.conf`:
     ```text
     KWIN_DRM_NO_AMS=0
     ```

### 6. AC Power Suspend Redirect
* **The Issue:** Closing the lid on battery hibernates after 15 minutes, but plugged into AC it stays in suspend forever.
* **The Root Cause:** Systemd suppresses hibernate on AC power by default, and KDE Plasma's AC profile calls standard `systemd-suspend.service` instead of `suspend-then-hibernate`.
* **The Solution:**
  1. Set `HibernateOnACPower=yes` in `/etc/systemd/sleep.conf.d/suspend-then-hibernate.conf`.
  2. Redirect `systemd-suspend.service` to `suspend-then-hibernate` via drop-in:
     ```ini
     [Service]
     Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0
     ExecStart=
     ExecStart=/usr/lib/systemd/systemd-sleep suspend-then-hibernate
     ```

### 7. Systemd timerfd Race (Suspend-then-Hibernate Runner)
* **The Issue:** The 15-minute RTC handoff fired early or was missed entirely on Intel Core Ultra / Arrow Lake platforms.
* **The Root Cause:** Upstream `systemd-sleep suspend-then-hibernate` relies on an internal timerfd that races on modern Intel Core Ultra / Arrow Lake platforms.
* **The Solution:** Replace it with `/usr/local/bin/suspend-then-hibernate-runner`, which arms the RTC via `rtcwake` and uses elapsed-time evaluation (`$ELAPSED >= $THRESHOLD`) to decide whether to hibernate or return to the desktop. Install the runner and the `override-runner.conf` drop-in:
  ```bash
  sudo install -m 0755 bin/suspend-then-hibernate-runner /usr/local/bin/suspend-then-hibernate-runner
  sudo mkdir -p /etc/systemd/system/systemd-suspend-then-hibernate.service.d
  sudo tee /etc/systemd/system/systemd-suspend-then-hibernate.service.d/override-runner.conf << 'EOF'
  [Service]
  ExecStart=
  ExecStart=/usr/local/bin/suspend-then-hibernate-runner
  EOF
  ```

### 8. NVIDIA Audio (`snd_hda_intel`) PCIe Wake Crash
* **The Issue:** On resume from `s2idle`, the NVIDIA audio controller (`0000:02:00.1`) re-enumerates and crashes `snd_hda_intel`.
* **The Fix:** Udev rule stripping all PCI devices with `vendor==0x10de`, plus disabling `snd_hda_intel` probe on HDMI.

### 9. `nvidia-fallback` / Plymouth DRM Master Deadlock
* **The Issue:** On resume from RAM, Fedora launches `nvidia-fallback.service`, calling `/bin/plymouth message`. Plymouth and KWin race for DRM Master at hibernation entry console switch, causing a hard freeze.
* **The Fix:** Masking `nvidia-fallback.service` and Plymouth sleep services.

### 10. Resume Sleep Guard vs Runner Race
* **The Issue:** Post-resume sleep inhibitor blocking automated hibernation.
* **The Fix:** The runner explicitly stops active sleep-guard instances and allows 3 seconds for PCIe bus and udev rules to settle before triggering hibernation.

---

## Step-by-Step Configuration Commands

### Step 1: Kernel Arguments
```bash
# 1. Identify your swap UUID
SWAP_UUID=$(lsblk -no UUID $(swapon --show=NAME --noheadings | head -n1))

# 2. Apply resume target, display transceiver fixes, and NVIDIA blacklist
sudo grubby --update-kernel=ALL --args="resume=UUID=${SWAP_UUID} i915.enable_psr=0 i915.fastboot=0 pm_async=0 rd.driver.blacklist=nouveau,nova_core,nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm modprobe.blacklist=nouveau,nova_core,nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm"
```

### Step 2: Systemd Sleep & Hibernate Modes
```bash
# Force shutdown mode and allow AC hibernation
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

### Step 3: KWin Wayland Display Resume Fixes
```bash
# 1. User environment variable
mkdir -p ~/.config/environment.d
echo "KWIN_DRM_NO_AMS=0" >> ~/.config/environment.d/kwin.conf

# 2. Hibernate service drop-in (unfreeze user session)
sudo mkdir -p /etc/systemd/system/systemd-hibernate.service.d
sudo tee /etc/systemd/system/systemd-hibernate.service.d/kwin-fix.conf << 'EOF'
[Service]
Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0
EOF

# 3. Suspend-then-hibernate service drop-in
sudo mkdir -p /etc/systemd/system/systemd-suspend-then-hibernate.service.d
sudo ln -sf /etc/systemd/system/systemd-hibernate.service.d/kwin-fix.conf /etc/systemd/system/systemd-suspend-then-hibernate.service.d/kwin-fix.conf

# 4. Universal suspend redirect (handles AC power & KDE lid triggers)
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

## Verification & How to Read the Logs

After triggering hibernation (`sudo systemctl hibernate`), wake the machine and inspect the successful lifecycle in the journal:

```bash
# Inspect the memory compression and write speed:
journalctl -k -b 0 --no-pager | grep -E -i "(PM:.*hibernation|image|restored|pages)"

# Inspect systemd's service lifecycle timings:
journalctl -b 0 -u systemd-hibernate.service --no-pager
```

Expected log output:
```text
PM: hibernation: Preallocating image memory
PM: hibernation: Allocated ~1917824 pages for snapshot (~3169.95 MB/s)
PM: hibernation: Hibernation image restored successfully.
PM: hibernation: Basic memory bitmaps freed
systemd[1]: Finished systemd-hibernate.service - System Hibernate (Consumed ~2.8s CPU time).
```
```

---

#### 2. Update `suspend-then-hibernation.md`

In your existing `suspend-then-hibernation.md`, replace **Step 4, Step 5, and Step 6** with the unified configuration so that the **AC power redirect** and **EnvyControl workflow** match reality:

```markdown
### Step 4: Configure `systemd` Sleep & AC Support

Create the sleep configuration drop-in:
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

### Step 5: Fix KDE Plasma Wayland / KWin Display Wake

1. **User session environment:**
   ```bash
   mkdir -p ~/.config/environment.d
   echo "KWIN_DRM_NO_AMS=0" >> ~/.config/environment.d/kwin.conf
   ```

2. **Systemd service drop-ins for all sleep services:**
   ```bash
   # Hibernate service
   sudo mkdir -p /etc/systemd/system/systemd-hibernate.service.d
   sudo tee /etc/systemd/system/systemd-hibernate.service.d/kwin-fix.conf << 'EOF'
   [Service]
   Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0
   EOF

   # Suspend-then-hibernate service
   sudo mkdir -p /etc/systemd/system/systemd-suspend-then-hibernate.service.d
   sudo ln -sf /etc/systemd/system/systemd-hibernate.service.d/kwin-fix.conf /etc/systemd/system/systemd-suspend-then-hibernate.service.d/kwin-fix.conf

   # Universal AC / Lid redirect (intercepts plain suspend)
   sudo mkdir -p /etc/systemd/system/systemd-suspend.service.d
   sudo tee /etc/systemd/system/systemd-suspend.service.d/override-to-suspend-then-hibernate.conf << 'EOF'
   [Service]
   Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0
   ExecStart=
   ExecStart=/usr/lib/systemd/systemd-sleep suspend-then-hibernate
   EOF

   sudo systemctl daemon-reload
   ```
