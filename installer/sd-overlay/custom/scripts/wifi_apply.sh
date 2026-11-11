#!/bin/sh
# CAMECRACK replacement for the toolkit's wifi_apply.sh. The stock station_connect.sh breaks on
# an apostrophe in SSID/password, so use the fixed connector, with retries. Log stays on the SD.
# In SD/toolkit mode we are started while the stock firmware sits in its own AP mode
# (wlan0 = 172.14.10.1, udhcpd running): tear that down first, and never take an AP address
# (172.14.10.1 stock / 10.1.8.1 ours) for a working station connection.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
SD_DIR=/tmp/sd
FIX="$SD_DIR/custom/scripts/wifi_up_fixed.sh"
LOG="$SD_DIR/logs/wifi_fixed.log"
mkdir -p "$SD_DIR/logs"
log(){ echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }
sta_ip(){ ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p'; }
have_ip(){ ip=$(sta_ip); [ -n "$ip" ] && [ "$ip" != "172.14.10.1" ] && [ "$ip" != "10.1.8.1" ]; }
log "wifi_apply (patched v2) start"
i=0; while [ $i -lt 60 ] && [ ! -e /sys/class/net/wlan0 ]; do i=$((i+1)); sleep 1; done
log "wlan0 after ${i}s, ip before=[$(sta_ip)]"
killall udhcpd hostapd udhcpc wpa_supplicant 2>/dev/null
ifconfig wlan0 0.0.0.0 2>/dev/null
n=0
while [ $n -lt 12 ]; do
  have_ip && break
  log "attempt $n"
  /bin/sh "$FIX" >> "$LOG" 2>&1
  sleep 10
  n=$((n+1))
done
if have_ip; then log "WIFI OK ip=$(sta_ip)"; else log "WIFI FAILED (ip=[$(sta_ip)]) wpa_state=$(wpa_cli -iwlan0 status 2>/dev/null | sed -n 's/^wpa_state=//p')"; fi
