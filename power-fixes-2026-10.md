# Resume, Clock, Power & Display Fixes — 27 Oct 2026

Hardware: PCSpecialist Ionico Ii 16
CPU: Intel Arrow Lake-S (24 cores)
GPU: Intel iGPU (i915) + NVIDIA dGPU (EnvyControl integrated-only mode)
BIOS: N.1.17PCS12 (2025-07-21)
Kernel: 7.2.11-200.fc44.x86_64
systemd: 259.10-1.fc44
PowerDevil: 6.7.5
KDE Plasma: 6.7.5

This document covers the fixes applied on 27 Oct 2026 for suspend-then-hibernate
re-suspend, clock jumps, debug logging, boot text, and the remaining
display/lag/power issues.

---

## 1. Suspend-then-hibernate re-suspend loop (FIXED)

**Problem:** After resuming from hibernation with the lid closed, PowerDevil
re-applied the lid action within seconds, immediately starting another sleep
cycle. The machine appeared to wake up only to go straight back to sleep.

### The closed-lid-after-resume bug

When the laptop lid is closed and the system resumes from suspend or hibernation,
KDE PowerDevil re-applies the configured lid action a few seconds later:

- ~2 s after resume when the screen configuration is reloaded
- ~10 s after resume from PowerDevil's wakeup check

With "suspend then hibernate" configured, this immediately starts a whole new
suspend cycle. The result: the laptop wakes up from hibernation, then
immediately goes back to sleep — an infinite loop that drains the battery
and makes the machine unusable while closed.

**Timeline observed (before fix):**
```
12:40:57  resume from hibernate (lid closed)
12:41:01  PowerDevil suspends again (4 s later)
12:41:04  resume (3 s later)
12:41:15  suspend again (11 s later)
12:42:39  resume (84 s later)
12:42:50  suspend again (11 s later)
```

KWin also logged "Failed to delay sleep: The operation inhibition has been
requested for is already running" at 12:41:15, confirming the race between
PowerDevil and the suspend inhibitor.

**Root cause:** PowerDevil re-applying the lid action after resume, not logind
lid handling. PowerDevil uses KDE SessionManagement/non-flags D-Bus calls;
logind's HANDLE_SUSPEND_THEN_HIBERNATE has inhibit_what=INHIBIT_SLEEP, so a
block inhibitor can block it.

**Fix applied:**
- PowerDevil config (`~/.config/powerdevilrc`): AC/Battery/LowBattery all set
  to `LidAction=1`, `SleepMode=3` (SuspendThenHibernate),
  `InhibitLidActionWhenExternalMonitorPresent=true`
- Original config backed up to `~/.config/powerdevilrc.before-sleep-fix`
- Root: consolidated sleep config at `/etc/systemd/sleep.conf.d/50-sleep-fix.conf`
  (HibernateMode=shutdown, HibernateDelaySec=15min, HibernateOnACPower=yes)
- Root: removed old ExecStart hack from
  `/etc/systemd/system/systemd-suspend.service.d/override-to-suspend-then-hibernate.conf`
- Root: installed `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0` in
  `/etc/systemd/system/systemd-suspend.service.d/kwin-fix.conf`
- Root: installed post-resume sleep guard at
  `/usr/lib/systemd/system-sleep/50-resume-sleep-guard`
  (25 s block inhibitor on sleep, releases early when lid opens)

### How the sleep guard works

The guard (`50-resume-sleep-guard`) is a systemd-sleep hook that runs after
every resume. If the lid is closed after resume, it:

1. Retries acquiring a block inhibitor on `sleep` (logind rejects new
   inhibitors until the sleep job that just finished is fully gone —
   "The operation inhibition has been requested for is already running")
2. Holds the inhibitor for up to 25 seconds, or releases early when the lid
   opens
3. PowerDevil's early suspend request is rejected with "Operation denied due
   to active block inhibitor" and PowerDevil does not retry

The inhibitor is released as soon as the lid is physically opened, so
closing the lid again shortly afterwards works normally.

**Guard log after successful resume (example):**
```
resume-sleep-guard: Lid reported closed after resume (suspend-then-hibernate, source: proc); arming sleep guard
resume-sleep-guard: Sleep inhibitor acquired (watch: proc, max: 25s)
```

**Backups:** `/var/backups/sleep-fix-20261027-152800/`

**Verification:** `/tmp/opencode/sleep-fix/verify.sh`

**Log check after next resume:**
```bash
journalctl -b -1 -o short-precise | grep -iE 'resume-sleep-guard|inhibitor|Performing sleep'
```

---

## 2. Clock jumps +1 hour on every resume (FIXED)

**Problem:** After every resume from sleep/hibernate, the system clock was 1 hour
fast (CET). chronyd spent hours slewing it back.

**Root cause:** RTC configured as local time (dual-boot with Windows). The kernel
reads the RTC as UTC on resume, adding the timezone offset.

**Fix applied:** Staged at `/tmp/opencode/resume-fixes/`
- `/usr/lib/systemd/system-sleep/50-rtc-local-fix`: post-resume hook running
  `hwclock --hctosys` to correct the clock. Only runs when `/etc/adjtime`
  says LOCAL (no-op if UTC).
- Debug kernel flags removed: `pm_async=0 no_console_suspend ignore_loglevel
  initcall_debug i915.fastboot=0`
- `i915.enable_psr=0 pm_async=0 i915.fastboot=0` re-added for hibernation
  stability via `/tmp/opencode/hibernation-fix/install.sh`

**Install:**
```bash
sudo /tmp/opencode/resume-fixes/install.sh
sudo reboot
```

**Verify:**
```bash
cat /proc/cmdline
# Expected: i915.enable_psr=0 pm_async=0 i915.fastboot=0 present
sudo /usr/lib/systemd/system-sleep/50-rtc-local-fix post suspend
journalctl -t rtc-local-fix -n 5 --no-pager
```

---

## 3. Kernel debug logging reduction (FIXED)

**Problem:** Console loglevel 7 (debug) caused all PM debug messages to print.
`printk_devkmsg = on` allowed unlimited userspace injection.

**Fix applied:** Staged at `/tmp/opencode/disable-debug/`
- `/etc/sysctl.d/99-disable-debug.conf`: `kernel.printk = 4 4 1 4`,
  `kernel.printk_devkmsg = ratelimit`

**Install:**
```bash
sudo /tmp/opencode/disable-debug/install.sh
```

**Verify:**
```bash
sysctl kernel.printk kernel.printk_devkmsg
# Expected: kernel.printk = 4 4 1 4, kernel.printk_devkmsg = ratelimit
```

---

## 4. Quiet boot (FIXED)

**Problem:** Kernel boot messages scrolled on screen during startup and shutdown.
No Plymouth splash screen.

**Root cause:** Missing `quiet rhgb` flags. `GRUB_TERMINAL_OUTPUT="console"`
forced text mode.

**Fix applied:** Staged at `/tmp/opencode/quiet-boot/`
- Added `rhgb quiet` to `/etc/default/grub` and `/etc/kernel/cmdline`
- Removed `GRUB_TERMINAL_OUTPUT="console"`
- Plymouth theme: bgrt (default Fedora)

**Install:**
```bash
sudo /tmp/opencode/quiet-boot/install.sh
sudo reboot
```

---

## 5. Display glitching (PARTIALLY ADDRESSED)

**Evidence:**
- Previous boot: "Applying output configuration failed!" at hibernate entry/resume
- Current boot: "atomic commit failed: Permission denied" at suspend entry
- "atomic commit failed: Device or resource busy" at 08:01, 08:31, 08:33, 09:06, 14:43
- eDP-1: 60 Hz selected (180 Hz available), VRR: Always
- External: Dell DP-2 1920x1080@120, VRR: Never

**Fixes applied:**
- `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0` (addresses Permission denied commits)

**Still to test:**
```bash
# VRR change (live, reversible)
kscreen-doctor output.eDP-1.vrrpolicy.automatic
kscreen-doctor output.eDP-1.vrrpolicy.never
kscreen-doctor output.eDP-1.vrrpolicy.always

# 180 Hz test
kscreen-doctor output.eDP-1.mode.2560x1600@180
kscreen-doctor output.eDP-1.mode.2560x1600@60
```

---

## 6. Post-resume lag (NOT YET ADDRESSED)

**Contributors:**
- tuned `powersave` on AC: no_turbo=1, EPP power, platform low-power, ~1.9 GHz
- Telegram 151% CPU, Java ~48%, load ~4
- 3622 wakeups/s at idle, 15.9 W discharge
- 19 Docker containers, MySQL, node, PostgREST running

**Fixes:**
```bash
# Switch to Balanced on AC
sudo tuned-adm profile balanced

# Stop idle Docker containers
docker stop $(docker ps -q)

# Powertop auto-tune
sudo powertop --auto-tune

# Pause MegaSync on battery
killall -STOP megasync

# Re-enable PSR (test for flicker)
sudo grubby --update-kernel=ALL --remove-args="i915.enable_psr=0"
sudo reboot
```

**Expected result:** idle power ~8-11 W (from 15.9 W), battery life ~10-12 hours

---

## 7. NMI after hibernate resume (MONITORING)

**Evidence:** "Uhhuh. NMI received for unknown reason 2c on CPU 0" at 13:46:24
and 06:44:06. 76 seconds after resume.

**Status:** nmi_watchdog=0 already (tuned powersave). Not the standard watchdog.
Likely firmware/PMU/thermal. If it persists, BIOS update from N.1.17PCS12.

---

## 8. NVIDIA dGPU (integrated-only, intentional)

**Status:** EnvyControl blacklist in place. dGPU re-enumerates on resume via pciehp.
`snd_hda_intel` probes GPU audio and logs "GPU sound probed, but not operational".
Adds resume work/noise but not a primary cause.

**Decision:** Keep integrated-only. No changes.

---

## 9. SELinux denials (NEW, recurring)

**Evidence:** 380+ events: "SELinux is preventing 20-chrony-dhcp/nm-dispatcher
from using sys_resource/sys_admin capability."

**Status:** Not sleep-related. From DHCP-renewal dispatcher scripts. Doesn't break
networking (static NTP server configured).

**Investigate:**
```bash
sealert -l 1d82d6d3-d2ef-41ce-9550-09ded6f576e4
sealert -l 985e6b20-20b8-492b-b59d-33dfee970377
sealert -l bab58c34-ae95-4460-851c-b62def1c7026
sealert -l 908fe35f-654e-4037-9a10-1b987de061e9
```

---

## Key config files

| File | Purpose |
|---|---|
| `~/.config/powerdevilrc` | PowerDevil: LidAction=1, SleepMode=3, InhibitLidWhenExternalMonitor=true |
| `~/.config/powerdevilrc.before-sleep-fix` | Original PowerDevil config backup |
| `~/.config/kwinoutputconfig.json` | Display: eDP-1 60 Hz (180 available), VRR Always; DP-2 1920x1080@120, VRR Never |
| `/etc/systemd/sleep.conf.d/50-sleep-fix.conf` | HibernateMode=shutdown, HibernateDelaySec=15min |
| `/etc/systemd/system/systemd-suspend.service.d/kwin-fix.conf` | SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0 |
| `/etc/systemd/system/systemd-suspend.service.d/nvidia-suspend-nofreeze.conf` | SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false |
| `/usr/lib/systemd/system-sleep/50-resume-sleep-guard` | Post-resume sleep inhibitor (25 s) |
| `/usr/lib/systemd/system-sleep/50-rtc-local-fix` | Post-resume clock correction |
| `/etc/sysctl.d/99-disable-debug.conf` | printk loglevel 4, devkmsg ratelimit |
| `/etc/default/grub` | GRUB_CMDLINE_LINUX (clean + rhgb quiet + hibernation flags) |
| `/etc/kernel/cmdline` | Kernel cmdline (same as above) |
| `/etc/modprobe.d/blacklist-nvidia.conf` | EnvyControl-generated NVIDIA blacklist |

## Hardware notes

- BIOS: N.1.17PCS12 (2025-07-21) — check for updates if NMI persists
- Swap: /dev/nvme0n1p7, 66.4 GB, resume UUID 119ba16f-303c-4295-9e5d-2f5345f33b32
- /sys/power/disk: platform (kernel default, systemd sets to shutdown on hibernate)
- /sys/power/state: freeze mem disk
- Intel iGPU on i915, NVIDIA dGPU blacklisted (EnvyControl integrated-only)
- tuned profile: powersave (no_turbo=1, EPP power, platform low-power)
- RTC: local time (dual-boot with Windows)
- NMI watchdog: 0 (disabled by tuned powersave profile)

## Quick reference commands

```bash
# Check current state
cat /proc/cmdline
timedatectl
tuned-adm active
kscreen-doctor -o | grep -E 'Output:|Modes:|Vrr:'

# Test sleep guard (after next resume)
journalctl -b -1 -o short-precise | grep -iE 'resume-sleep-guard|rtc-local-fix|Performing sleep'

# Test VRR change (live, reversible)
kscreen-doctor output.eDP-1.vrrpolicy.automatic
kscreen-doctor output.eDP-1.vrrpolicy.never
kscreen-doctor output.eDP-1.vrrpolicy.always

# Test 180 Hz (live, reversible)
kscreen-doctor output.eDP-1.mode.2560x1600@180
kscreen-doctor output.eDP-1.mode.2560x1600@60

# Power profile
sudo tuned-adm profile balanced      # on AC
sudo tuned-adm profile powersave     # on battery

# Powertop
sudo powertop --auto-tune
sudo powertop --html=/tmp/powertop.html

# SELinux
sealert -l 1d82d6d3-d2ef-41ce-9550-09ded6f576e4
sealert -l 985e6b20-20b8-492b-b59d-33dfee970377
sealert -l bab58c34-ae95-4460-851c-b62def1c7026
sealert -l 908fe35f-654e-4037-9a10-1b987de061e9
```

## Staged scripts reference

| Directory | Script | Purpose |
|---|---|---|
| `/tmp/opencode/sleep-fix/` | `install.sh` | Sleep guard + consolidated config (already installed) |
| `/tmp/opencode/sleep-fix/` | `verify.sh` | Read-only verification |
| `/tmp/opencode/sleep-fix/` | `uninstall.sh` | Restore original sleep config |
| `/tmp/opencode/resume-fixes/` | `install.sh` | RTC clock hook + kernel debug flag removal |
| `/tmp/opencode/resume-fixes/` | `uninstall.sh` | Restore kernel flags + remove hook |
| `/tmp/opencode/hibernation-fix/` | `install.sh` | Re-add i915.enable_psr=0, pm_async=0, i915.fastboot=0 |
| `/tmp/opencode/disable-debug/` | `install.sh` | Lower printk loglevel + devkmsg ratelimit |
| `/tmp/opencode/quiet-boot/` | `install.sh` | Add rhgb quiet + restore graphical terminal |
| `/tmp/opencode/quiet-boot/` | `uninstall.sh` | Restore text boot |
