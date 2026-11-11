#!/bin/sh
# CAMECRACK: replacement for the stock /usr/sbin/recover_cfg.sh (bind-mounted by boot.sh).
# anyka_ipc runs "sh /usr/sbin/recover_cfg.sh" on a LONG press of the reset button, then
# beeps and reboots by itself. The stock script wiped the Tuya config (factory reset);
# ours wipes nothing and asks extras.sh to start the setup hotspot (AP mode) at the next
# boot, so a long press = "reset to the hotspot". wifi.conf is kept: with no phone joining
# within 10 min, the camera reboots and goes back to its saved Wi-Fi.
CC=/etc/config/camecrack
: > "$CC/ap_next"
sync
echo "[$(date +%H:%M:%S)] long press: hotspot at next boot (Tuya reset ignored)" >> "$CC/boot.log"
exit 0
