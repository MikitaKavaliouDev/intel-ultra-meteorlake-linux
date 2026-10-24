

### Step 1: Create the Monitoring Script

Run this command in your terminal to install it to `/usr/local/bin/power-mon`:

```bash
sudo tee /usr/local/bin/power-mon << 'EOF'
#!/usr/bin/env bash

# Auto-detect battery device
BAT=$(upower -e | grep -m1 'BAT')

if [ -z "$BAT" ]; then
    echo "Error: No battery detected by upower."
    exit 1
fi

# Refresh interval (default 2 seconds, or first argument)
INTERVAL="${1:-2}"

# Restore cursor on exit (Ctrl+C)
trap 'tput cnorm; echo -e "\nExiting..."; exit 0' INT TERM
tput civis # Hide cursor for flicker-free display

while true; do
    clear
    echo "=================================================="
    echo "            REAL-TIME POWER MONITOR               "
    echo "           (Press Ctrl+C to exit | ${INTERVAL}s)          "
    echo "=================================================="
    
    # Show active GPU mode so you can see if NVIDIA is awake
    if command -v envycontrol &>/dev/null; then
        GPU_MODE=$(envycontrol -q 2>/dev/null || echo "unknown")
        echo -e " Active GPU Mode    : \033[1;36m$GPU_MODE\033[0m"
        echo "--------------------------------------------------"
    fi

    # Display key battery metrics
    upower -i "$BAT" | grep -E "state|percentage|energy-rate|time to empty|time to full|voltage" | while read -r line; do
        if echo "$line" | grep -q "energy-rate"; then
            # Highlight wattage in yellow/bold
            echo -e " \033[1;33m$line\033[0m"
        elif echo "$line" | grep -q "time to empty"; then
            # Highlight remaining time in green
            echo -e " \033[1;32m$line\033[0m"
        else
            echo " $line"
        fi
    done

    echo "=================================================="
    sleep "$INTERVAL"
done
EOF
sudo chmod +x /usr/local/bin/power-mon
```

---

### Step 2: How to Run It

Simply run:
```bash
power-mon
```

#### Optional: Custom Refresh Rate
You can specify how fast it refreshes in seconds:
* Update every 1 second:
  ```bash
  power-mon 1
  ```
* Update every 5 seconds:
  ```bash
  power-mon 5
  ```

---

### What to Look For

* **In `integrated` mode:** After a few seconds of idle, your `energy-rate` should drop down to around **5W – 9W** (extending battery life to 6+ hours).
* **In `hybrid` mode (`game-on`):** Because KWin keeps the NVIDIA card awake, the `energy-rate` will hover higher around **15W – 22W** (as shown in your ~18.4W reading).