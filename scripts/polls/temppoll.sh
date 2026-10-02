#!/bin/bash

# CPU temperature in °C (one decimal), straight from the CPU's own hwmon
# sensor: k10temp's Tctl (AMD) or coretemp's package sensor (Intel).
# `sensors` read every chip instead, and the first one it listed isn't always
# the CPU (the desktop's was the Ethernet PHY); reading a discrete amdgpu's
# sensors also wakes it from runtime suspend, so polling it every 2 s kept a
# hybrid laptop's dGPU powered up for good.
for d in /sys/class/hwmon/hwmon*; do
    case $(<"$d/name") in
        k10temp | zenpower) f=$d/temp1_input ;;
        coretemp)
            f=$d/temp1_input
            for l in "$d"/temp*_label; do
                if [[ $(<"$l") == Package* ]]; then f=${l%_label}_input; break; fi
            done
            ;;
        *) continue ;;
    esac
    if read -r t <"$f"; then
        printf '%d.%d\n' $((t / 1000)) $((t % 1000 / 100))
        exit
    fi
done

# No known CPU sensor: the first reading `sensors` lists
sensors | head -n 3 | tail -n 1 | grep -oP '\+\K\d+\.\d+' | head -1
