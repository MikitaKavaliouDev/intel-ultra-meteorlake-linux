
#!/usr/bin/env bash

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[1;36m'

header() {
    echo -e "\n${C_BOLD}${C_CYAN}================================================================${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}  $1${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}================================================================${C_RESET}"
}

header "1. SYSTEMD-SUSPEND-THEN-HIBERNATE SERVICE LOGS (CURRENT & PREV BOOT)"
echo -e "${C_BOLD}--- Current Boot (-b 0) ---${C_RESET}"
journalctl -b 0 -u systemd-suspend-then-hibernate.service --no-pager || echo "No entries in current boot."

echo -e "\n${C_BOLD}--- Previous Boot (-b -1) ---${C_RESET}"
journalctl -b -1 -u systemd-suspend-then-hibernate.service --no-pager || echo "No entries in previous boot."

header "2. SLEEP OPERATION TRANSITIONS & TIMER WAKE (LAST 2 ATTEMPTS)"
journalctl -k --no-pager | grep -E -i "(PM: suspend entry|PM: suspend exit|PM: hibernation entry|hibernation exit|RTC can wake|woken_by_timer|wakealarm|alarmtimer)" | tail -n 35

header "3. SYSTEMD-SLEEP EXECUTION TRACE (DID IT ENTER HIBERNATE?)"
journalctl --no-pager | grep -E -i "(Performing sleep operation|System returned from sleep operation|User sessions remain unfrozen)" | tail -n 25

header "4. SLEEP GUARD & RTC LOCAL FIX HOOK LOGS"
echo -e "${C_BOLD}--- 50-resume-sleep-guard ---${C_RESET}"
journalctl --no-pager -t resume-sleep-guard | tail -n 25 || echo "No sleep-guard logs found."

echo -e "\n${C_BOLD}--- 50-rtc-local-fix ---${C_RESET}"
journalctl --no-pager -t rtc-local-fix | tail -n 15 || echo "No rtc-local-fix logs found."

header "5. LID SWITCH & POWERDEVIL D-BUS EVENTS"
journalctl --no-pager | grep -E -i "(Lid closed|Lid opened|HandleLidSwitch|Switching to 'suspend-then-hibernate'|Operation denied due to active block inhibitor)" | tail -n 25

header "6. ACTIVE SLEEP INHIBITORS (ARE ANY APPS BLOCKING SLEEP?)"
systemd-inhibit --no-pager --list

header "7. SLEEP & RTC CONFIGURATION AUDIT"
echo -e "${C_BOLD}Consolidated Sleep Configuration:${C_RESET}"
systemd-analyze cat-config systemd/sleep.conf | grep -E -v '^(#|$)'

echo -e "\n${C_BOLD}RTC CMOS Alarm Module Parameters:${C_RESET}"
echo -e "use_acpi_alarm : ${C_YELLOW}$(cat /sys/module/rtc_cmos/parameters/use_acpi_alarm 2>/dev/null || echo 'N/A')${C_RESET}"

header "8. SWAP PARTITION CURRENT SIGNATURE"
SWAP_SIG=$(sudo dd if=/dev/nvme0n1p7 bs=4096 count=1 2>/dev/null | strings | head -n 3 | tr -d '\n')
echo -e "Current Signature on /dev/nvme0n1p7 : ${C_BOLD}${SWAP_SIG}${C_RESET}"
if echo "$SWAP_SIG" | grep -q "SWSUSP"; then
    echo -e "Status : ${C_GREEN}Contains un-restored hibernation image!${C_RESET}"
else
    echo -e "Status : ${C_YELLOW}Clean swap (no hibernation image waiting)${C_RESET}"
fi

echo -e "\n${C_BOLD}${C_GREEN}Report complete!${C_RESET}\n"
EOF

chmod +x ./sleep-logger.sh
sudo ./sleep-logger.sh
