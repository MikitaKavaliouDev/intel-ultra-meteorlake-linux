
# PCSpecialist Ionico II 16 (Intel Core Ultra 9 275HX) Linux Power Management
### Complete Fix for Suspend-then-Hibernate, 0W Idle Battery Life & NVIDIA Gaming on Fedora / KDE Plasma 6 (Wayland)

[![Fedora 44](https://img.shields.io/badge/Fedora-44-blue.svg)](https://getfedora.org)
[![Desktop: KDE Plasma 6](https://img.shields.io/badge/KDE%20Plasma-6-informational.svg)](https://kde.org/plasma-desktop/)
[![Hardware: Tongfang / Uniwill](https://img.shields.io/badge/Chassis-Uniwill%20%2F%20Tongfang-orange.svg)](https://www.pcspecialist.co.uk)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)

---

## Hardware Compatibility

This repository provides automated fixes and documentation for the **PCSpecialist Ionico II 16** and equivalent **Tongfang / Uniwill barebone chassis** (also sold internationally under brands like XMG, Eluktronics, and Medion Erazer).

| Component | Tested Specification |
| :--- | :--- |
| **Model** | PCSpecialist Ionico II 16 (Uniwill GM6HG chassis) |
| **Processor** | Intel Core Ultra 9 275HX (Arrow Lake-HX, 24 Cores / 24 Threads) @ 5.40 GHz |
| **Integrated GPU** | Intel Arc Graphics / Xe-LPG (Device ID `7d67`) |
| **Discrete GPU** | NVIDIA GeForce RTX Mobile (GB206M / RTX 5060 Mobile) |
| **Memory** | 64 GB DDR5 |
| **Swap Target** | 66.4 GB Dedicated NVMe Partition (`/dev/nvme0n1p7`) |
| **Display** | 16" 2560x1600 (16:10 QHD+), 60 Hz / 240 Hz |
| **OS / Kernel** | Fedora Linux 44 (x86_64) • Kernel 7.2.x+ |
| **Compositor** | KWin (Wayland) on KDE Plasma 6.7+ |

---

## Technical Problems Solved

1. **ACPI S4 Firmware Hang:** Motherboard UEFI locks up when calling ACPI S4 (`platform`) sleep.  
   **Fix:** Enforces OS-level `HibernateMode=shutdown`.
2. **NVIDIA Driver Shutdown Deadlock:** During hibernation power-off, the proprietary NVIDIA driver wedges inside `nv_drm_dev_unload`.  
   **Fix:** Uses EnvyControl's `integrated` mode (`remove=1`) to physically detach the dGPU on boot, preventing deadlocks and achieving **true 0W idle**.
3. **KDE Plasma Wayland 10W Battery Drain:** KWin keeps persistent open DRM handles to secondary GPUs, preventing runtime `D3cold`.  
   **Fix:** Hardware-level PCIe detachment prevents KWin from holding DRM handles.
4. **Display Wake Failure (Dark Screen):** Intel's Panel Self Refresh (PSR2) fails display clock re-synchronization on cold wake.  
   **Fix:** Kernel flags `i915.enable_psr=0 i915.fastboot=0`.
5. **Driver Wake Race Condition:** Parallel driver resume causes display pipe initialization timeouts.  
   **Fix:** Kernel flag `pm_async=0`.
6. **KWin "Lit Black Screen" on Resume:** Systemd's cgroup freezer freezes `user.slice`, deadlocking KWin's DRM master release upon wake.  
   **Fix:** Service drop-in `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0` + `KWIN_DRM_NO_AMS=0`.
7. **Plugged-In Sleep Ignored:** Systemd suppresses hibernate on AC power, and KDE triggers plain suspend.  
   **Fix:** `HibernateOnACPower=yes` + redirecting `systemd-suspend.service` to `suspend-then-hibernate`.

---

## Quick Setup

### Prerequisites
1. You have a physical **SWAP partition** active that is **at least the size of your RAM** (64 GB RAM = ~66 GB swap). Check with `swapon --show`.
2. Install `envycontrol`:
   ```bash
   sudo dnf install python3-pip
   sudo pip install envycontrol
   ```

### 1-Step Automated Installation
```bash
git clone https://github.com/YOUR_USERNAME/ionico-16-linux-power.git
cd ionico-16-linux-power
chmod +x install.sh
sudo ./install.sh
```
*The installer automatically detects your active swap UUID, applies all `grubby` flags, configures systemd drop-ins, and installs the helper scripts.*

> **Prefer manual setup?** Check out the step-by-step technical guides:
> * [Comprehensive Suspend-Then-Hibernate Guide](suspend-then-hibernation.md)
> * [Hibernation Root Causes & Architecture Deep Dive](hibernation.md)
> * [On-Demand Gaming Architecture](game-on-off-nvidia.md)

---

## Daily Usage

### 1. Everyday Work & Travel (Intel Mode)
* **Battery Power Draw:** **~5W – 9W** (6+ hours of battery life).
* **Sleep Behavior:**
  * Close the lid (on battery OR plugged in): Suspends to RAM immediately (pulsing LED).
  * After **15 minutes**: Silently wakes, compresses RAM to NVMe swap, and cuts power completely (**0-Watt Hibernation**).
  * Press power button: Restores session in ~8 seconds.

### 2. Gaming Mode (`game-on`)
To play games on the dedicated NVIDIA GPU:
```bash
game-on
```
* Switches EnvyControl to `hybrid` mode.
* **Safety Lock:** Automatically masks hibernation services so accidental lid closes or clicks will never freeze the laptop while on NVIDIA.
* Prompts to reboot into gaming mode.

### 3. Returning to Daily Mode (`game-off`)
When you are done gaming:
```bash
game-off
```
* Switches EnvyControl back to `integrated` mode (cuts PCIe power to 0W).
* Automatically unmasks hibernation and suspend-then-hibernate.
* Prompts to reboot back into everyday mode.

### 4. Real-Time Power Monitor (`power-mon`)
Check live wattage, battery percentage, remaining time, and active GPU mode:
```bash
power-mon
```

---

## Verification & Health Check

| Command | Purpose | Expected Output in Everyday Mode |
| :--- | :--- | :--- |
| `envycontrol -q` | Check active GPU mode | `integrated` |
| `lspci \| grep -i nvidia` | Verify PCIe power cut | *(Empty / Nothing)* |
| `systemctl status systemd-hibernate.service` | Check sleep safety lock | `inactive (dead)` (or `masked` while gaming) |
| `journalctl -b 0 -u systemd-suspend-then-hibernate.service` | Inspect last sleep transition | Shows 15-minute handoff from suspend to hibernate |
| `sudo systemctl hibernate` | Test direct hibernation | Compresses RAM and powers off to 0.0W cleanly |

---

## License

This project is licensed under the [MIT License](LICENSE).
```