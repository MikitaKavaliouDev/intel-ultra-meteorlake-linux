# How Hibernation Was Solved: Technical Architecture & Root Causes
### PCSpecialist Ionico II 16 (Intel Core Ultra 9 275HX + NVIDIA RTX Mobile)

Getting hibernation and suspend-then-hibernate to work on this platform required solving **eight compounding failure points** across motherboard UEFI firmware, the proprietary NVIDIA driver, the PCIe bus controller, systemd, Plymouth, and the KWin Wayland compositor:

```
[System Trigger: suspend-then-hibernate / hibernate]
     │
     ├── 1. Swap Space Sizing ───────────► 64 GB RAM needed >64 GB physical NVMe swap (Fixed: 66.4 GB partition)
     │
     ├── 2. Plymouth DRM Deadlock ───────► 'rhgb quiet' contested KWin for DRM Master (Fixed: removed rhgb quiet)
     │
     ├── 3. Device Shutdown Freeze ──────► NVIDIA driver wedged in nv_drm_dev_unload (Fixed: EnvyControl integrated remove=1)
     │
     ├── 4. Power-Off Hang ──────────────► Motherboard UEFI hung on ACPI S4 (Fixed: HibernateMode=shutdown)
     │
[Wake / Timer Handoff]
     │
     ├── 5. PCIe Hotplug Re-Probe ───────► pciehp re-probed dGPU on S0ix wake (Fixed: pcie_ports=compat)
     │
     ├── 6. Upstream Timerfd Race ───────► systemd 0ms poll aborted handoff (Fixed: suspend-then-hibernate-runner)
     │
     ├── 7. Display Transceiver Desync ──► Intel Arc eDP CX0 transceiver failed link training (Fixed: i915.enable_psr=0, pm_async=0)
     │
     └── 8. "Lit Black Screen" Deadlock ─► cgroup freezer locked user.slice (Fixed: SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0)
```

---

### The 8 Failure Points Detailed

#### 1. NVMe Swap Sizing & Error Code `-22`
* **The Issue:** Boot logs repeatedly showed `PM: Image not found (code -22)`.
* **The Root Cause:** In Linux hibernation, error `-22` (`-EINVAL`) occurs on cold boot or after a failed wake because the kernel intentionally invalidates the `SWSUSP` header on swap upon reading it to prevent boot loops. A dedicated **66.4 GB physical NVMe swap partition** (`/dev/nvme0n1p7`) ensures the snapshot never encounters `-ENOSPC` (error `-28`).

#### 2. The Plymouth vs KWin DRM Master Conflict
* **The Issue:** Kernel hung immediately at `PM: hibernation: hibernation entry`, before filesystems could sync.
* **The Root Cause:** Because `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0` keeps KWin alive, adding `rhgb quiet` caused Plymouth to activate and attempt to claim DRM Master at the exact same moment KWin was holding it. The kernel DRM subsystem only permits one DRM Master, causing an unrecoverable display pipeline deadlock.
* **The Solution:** Completely purge `rhgb quiet` from kernel arguments and mask Plymouth sleep services.

#### 3. The NVIDIA Driver Teardown Deadlock
* **The Issue:** System froze during hibernation power-down right after `[nvidia-drm] Unloading driver`.
* **The Root Cause:** The proprietary NVIDIA module wedged in `nv_drm_dev_unload` while communicating with SBIOS/ACPI during PCI teardown.
* **The Solution:** EnvyControl’s `integrated` mode (`remove=1`) unbinds and detaches the card on boot. The card physically does not exist on the PCIe bus during normal boots, preventing the deadlock and achieving **true 0W idle**.

#### 4. The ACPI S4 Firmware Hang
* **The Issue:** Screen went black, but fans and power LEDs stayed on indefinitely.
* **The Root Cause:** Modern Tongfang / Uniwill UEFI firmwares do not properly implement the ACPI S4 (`platform`) sleep state.
* **The Solution:** Set `HibernateMode=shutdown` in systemd sleep configs and persist `shutdown` into `/sys/power/disk` via `systemd-tmpfiles`.

#### 5. PCIe Native Hotplug (`pciehp`) Re-Enumeration Race
* **The Issue:** Direct hibernate worked, but 15-minute `suspend-then-hibernate` froze at `hibernation entry`.
* **The Root Cause:** When waking from $S0\text{ix}$ suspend, the kernel's PCIe Native Hotplug driver (`pciehp`) detected the slot link-up on root port `0000:00:06.3` and re-probed the NVIDIA GPU and HDMI sound card. Udev immediately triggered `remove=1` while the runner called `hibernate`, deadlocking the bus (`parent 0000:00:06.3 should not be sleeping`).
* **The Solution:** Add `pcie_ports=compat` to the kernel command line to disable native PCIe hotplug on internal motherboard slots.

#### 6. Upstream Systemd Timerfd Race on Intel Arrow Lake
* **The Issue:** The 15-minute timer woke the laptop, but the system returned to desktop instead of hibernating, draining the battery in the backpack.
* **The Root Cause:** Upstream systemd polls `tfd` with a 0ms timeout upon wake from suspend. On Intel Core Ultra, the CPU wakes a fraction of a millisecond before the timer event registers in userspace, causing systemd to treat it as a user wake event and abort the handoff.
* **The Solution:** The custom `suspend-then-hibernate-runner` uses elapsed-time calculation ($T_{\text{elapsed}} \ge T_{\text{target}}$) and physical lid detection to reliably execute hibernation.

#### 7. Intel Arc Transceiver Link Failure (Cold Wake Black Screen)
* **The Issue:** Session restored, but the display panel remained completely black.
* **The Root Cause:** On Intel Meteor Lake / Arrow Lake integrated graphics (device ID `7d67`), Panel Self Refresh (PSR2) fails to re-synchronize display clock timings on cold wake. Asynchronous driver resume (`pm_async`) also causes display pipes to initialize before the PCIe bridge.
* **The Solution:** Kernel flags `i915.enable_psr=0` and `pm_async=0`.

#### 8. KWin Wayland "Lit Black Screen" Deadlock
* **The Issue:** On wake, the backlight turned on (screen was glowing black), but no desktop or cursor appeared.
* **The Root Cause:** Backlight power restored, but KWin failed to reacquire the DRM scanout buffer because systemd's cgroup freezer froze `user.slice` during sleep.
* **The Solution:** Add drop-in `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0` to all sleep services and set `KWIN_DRM_NO_AMS=0` in `~/.config/environment.d/kwin.conf`.
