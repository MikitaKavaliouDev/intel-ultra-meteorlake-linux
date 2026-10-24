# Dual-Mode Power Architecture: On-Demand Gaming & 0W Intel Hibernation
### Complete Setup & Technical Deep Dive for KDE Plasma 6 (Wayland) + EnvyControl

---

## 1. Technical Deep-Dive: Why This Setup Is Necessary

### The KDE Plasma 6 (Wayland) ~10W Battery Drain Bug
In modern Linux hybrid setups, the NVIDIA discrete GPU (dGPU) is supposed to utilize **Runtime D3 (RTD3) Power Management**. When no 3D application is running, the driver should drop the GPU into `D3cold` (sub-millivolt rail power, ~0 Watts).

However, on **KDE Plasma 6 Wayland**, KWin (the Wayland compositor) and Xwayland initialize and hold persistent DRM file descriptors (`/dev/dri/renderD129`) across all detected graphics adapters at login:
* This persistent handle prevents the NVIDIA GPU from ever dropping into `D3cold`.
* The card remains trapped in `D0` (Active) or `D3hot` (PCIe link active, clocks running).
* **The Result:** The dGPU constantly draws **8 to 12 Watts** of continuous power from the battery, cutting battery life in half even when sitting idle on the desktop.

---

### Why EnvyControl's `integrated` Mode Solves the Drain
Unlike simple driver blacklisting, EnvyControl’s `integrated` mode executes an aggressive hardware-level cut:
1. It injects a udev rule (`/etc/udev/rules.d/50-remove-nvidia.rules`) containing:
   ```udev
   ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x03[0-9]*", ATTR{remove}="1"
   ```
2. When the kernel discovers the NVIDIA card on the PCIe bus during boot, udev immediately instructs the kernel to **remove and unbind the device node completely**.
3. Because the card does not exist in `/sys/bus/pci/devices/`, KWin cannot open a DRM handle to it.
4. The motherboard's power rails cut power to the PCIe slot, delivering **true 0-Watt idle power consumption**.
5. **Why a reboot is required:** Modifying PCIe hardware enumeration and udev device detachment requires a clean kernel initialization; it cannot be toggled dynamically on a running Wayland session without crashing KWin.

---

### Why Hibernation Must Be Locked During Gaming Mode
When you switch to `hybrid` mode for gaming:
* The proprietary NVIDIA modules (`nvidia.ko`, `nvidia-drm.ko`) are loaded into the kernel.
* On modern laptops, during the final power-down phase of hibernation, the kernel calls `device_shutdown()`.
* The proprietary NVIDIA driver attempts to execute its unload sequence (`nv_drm_dev_unload`), fails to communicate with SBIOS/ACPI, and **deadlocks the entire CPU**.
* **The Safeguard:** Our `game-on` script automatically uses `systemctl mask` to lock both `systemd-hibernate.service` and `systemd-suspend-then-hibernate.service`. If you accidentally close your laptop lid or press Hibernate while gaming, the system simply ignores the request rather than deadlocking.

---

## 2. Installation & Script Setup

### Step 1: Ensure Executable Path Exists
```bash
sudo mkdir -p /usr/local/bin
```

---

### Step 2: Create `/usr/local/bin/game-on`

This script switches EnvyControl to `hybrid` mode, locks hibernation, and reboots into a full-performance gaming environment:

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

# 2. SAFETY: Lock hibernation to prevent driver teardown lockups during sleep
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

---

### Step 3: Create `/usr/local/bin/game-off`

This script returns EnvyControl to `integrated` mode (cutting PCIe power), restores full hibernation functionality, and reboots into daily mode:

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

## 3. Daily Workflow & Operation

### State A: Everyday Work & Travel (Intel-Only)
* **Status:** `envycontrol -q` reports `integrated`.
* **Power Draw:** NVIDIA GPU is completely unpowered (0 Watts). Battery life is maximized on Intel Arc.
* **Sleep Behavior:** 
  * Closing the lid puts the laptop to sleep immediately.
  * After 15 minutes, it automatically transitions into **Hibernation** (saving RAM to swap and powering off).
  * Opening the lid or pressing the power button restores your desktop in ~8 seconds.

---

### State B: Activating Gaming Mode
When you are ready to play games:

1. Open a terminal and run:
   ```bash
   game-on
   ```
2. Press `Enter` (or `Y`) to reboot.
3. The laptop boots with the NVIDIA GPU active and available.
4. **Performance:** You have 100% full GPU clocks, dedicated VRAM, Ray Tracing, and DLSS.
   * Games on Steam can be launched with:
     ```text
     __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia %command%
     ```
   * Or right-click any application in KDE Application Launcher and choose **"Launch with Dedicated Graphics"**.
5. **Safety:** Hibernation is completely masked. Accidental lid closes or clicks will not freeze the laptop.

---

### State C: Returning to Everyday Mode
When you are done gaming:

1. Open a terminal and run:
   ```bash
   game-off
   ```
2. Press `Enter` (or `Y`) to reboot.
3. The laptop boots back into `integrated` mode:
   * NVIDIA power rails are cut to 0 Watts.
   * Hibernation and 15-minute `suspend-then-hibernate` are automatically unlocked and ready to use.

---

## 4. Useful Verification Commands

| Check | Command | Expected Output in Everyday Mode | Expected Output in Gaming Mode |
| :--- | :--- | :--- | :--- |
| **Active GPU Mode** | `envycontrol -q` | `integrated` | `hybrid` |
| **PCIe Device Presence** | `lspci \| grep -i nvidia` | *(Empty / Nothing)* | Shows NVIDIA Controller |
| **Hibernation Safety Lock** | `systemctl status systemd-hibernate.service` | `Loaded: ... (inactive)` | `Loaded: masked` |
| **Total System Power Draw** | `sudo powertop` or `upower -d` | Low idle (~5-8W total system) | Higher idle (~15-20W total system) |