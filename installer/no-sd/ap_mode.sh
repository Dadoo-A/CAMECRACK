#!/bin/sh
# CAMECRACK: AP (hotspot) mode for OFFLINE Wi-Fi provisioning.
#   sh ap_mode.sh [reason]
# Open AP "CAMECRACK-<last 4 hex of MAC>", camera at 10.1.8.1, DHCP + wildcard DNS
# (captive portal) -> the webcfg page. Saving a network there writes wifi.conf and
# REBOOTS (the ATBM driver cannot go back AP->STA hot; rmmod panics the kernel).
# With no client around for AP_TIMEOUT seconds, it reboots too (= retries the station,
# e.g. the router was just slower than the camera to come back after a power cut).
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
CC=/etc/config/camecrack
LOG=$CC/boot.log
APIP=10.1.8.1
AP_TIMEOUT=${AP_TIMEOUT:-600}
log(){ echo "[$(date +%H:%M:%S)] ap: $*" >> "$LOG"; }

[ -f /tmp/camecrack_ap ] && { log "already in AP mode"; exit 0; }
[ -f "$CC/ap-bin.tar.xz" ] || { log "no ap-bin.tar.xz, AP mode unavailable"; exit 1; }
[ -e /sys/class/net/wlan0 ] || { log "no wlan0, AP mode unavailable"; exit 1; }
touch /tmp/camecrack_ap
log "entering AP mode (reason: ${1:-manual})"
# Status LED: user-chosen patterns (led.conf, see led.sh).
sh "$CC/led.sh" hotspot_starting

# 0. Right after boot (long press, no config) the camera app and its watchdog 'daemon'
#    are still starting: stopping them too early left the hardware watchdog armed and
#    the camera rebooted ~15 s after the AP came up (seen 2026-11-11). Let boot settle.
up=$(cut -d. -f1 /proc/uptime)
if [ "$up" -lt 75 ]; then
  log "boot settling: waiting $((75 - up)) s before AP"
  sleep $((75 - up))
fi
n=0; while ! pidof daemon >/dev/null && [ $n -lt 20 ]; do sleep 1; n=$((n+1)); done

# 1. Stop the camera app FIRST: it manages wlan0 itself and, seeing the station link
#    gone, does 'ifconfig wlan0 down' (kills the AP) or even reloads the driver (rmmod
#    => kernel panic). Same sequence as the stock service.sh stop: SIGUSR2 tells
#    'daemon' to close the hardware watchdog before we kill it.
killall -12 daemon 2>/dev/null
sleep 5
killall daemon 2>/dev/null
killall -9 anyka_ipc 2>/dev/null
killall wpa_supplicant udhcpc 2>/dev/null
# Open AP = no root shell for whoever joins it, unless explicitly allowed.
[ -f "$CC/ap_telnet" ] || killall telnetd 2>/dev/null

# 2. Binaries -> RAM (tmpfs). hostapd 2.8 static musl + captive-dns, one xz stream.
if ! xzcat "$CC/ap-bin.tar.xz" | tar -x -C /tmp; then
  log "unpack failed -> reboot"; sync; reboot; exit 1
fi

# 3. Configs (generated in RAM; nothing written to flash).
suf=$(awk -F: '{print toupper($5 $6)}' /sys/class/net/wlan0/address)
SSID="CAMECRACK-$suf"
cat > /tmp/hostapd.conf <<EOF
interface=wlan0
driver=nl80211
ssid=$SSID
channel=1
hw_mode=g
wmm_enabled=1
auth_algs=1
macaddr_acl=0
ignore_broadcast_ssid=0
EOF
cat > /tmp/udhcpd.conf <<EOF
interface wlan0
start 10.1.8.20
end 10.1.8.254
max_leases 16
lease_file /tmp/udhcpd.leases
option subnet 255.255.255.0
opt router $APIP
opt dns $APIP
option lease 3600
EOF
touch /tmp/udhcpd.leases

# 4. Bring the AP up. hostapd switches wlan0 STA->AP itself (works hot on this chip)
#    and uses a monitor interface for management frames (use_monitor auto-detected).
ifconfig wlan0 down
if ! /tmp/hostapd -B /tmp/hostapd.conf; then
  log "hostapd failed to start -> reboot"; sync; reboot; exit 1
fi
sleep 3
ifconfig wlan0 "$APIP" netmask 255.255.255.0 up
udhcpd /tmp/udhcpd.conf
/tmp/captive-dns "$APIP" -d
# The portal is the existing webcfg page (port 80); start it if it is not running.
pidof nc >/dev/null 2>&1 || { [ -f "$CC/webcfg.sh" ] && setsid /bin/sh "$CC/webcfg.sh" >/dev/null 2>&1 & }
if iwconfig wlan0 2>/dev/null | grep -q "Mode:Master"; then
  log "AP up: SSID=$SSID ip=$APIP (timeout ${AP_TIMEOUT}s without client)"
  sh "$CC/led.sh" hotspot_ready
else
  log "WARN: wlan0 not in Master mode after start"
fi

# 5. Supervise. Any failure -> reboot (back to station mode with the current wifi.conf).
idle=0
while :; do
  sleep 30
  if ! pidof hostapd >/dev/null 2>&1 || ! iwconfig wlan0 2>/dev/null | grep -q "Mode:Master"; then
    log "AP lost (hostapd=$(pidof hostapd)) -> reboot"; sync; reboot; exit 1
  fi
  if grep -q "^10\.1\.8\." /proc/net/arp; then idle=0; else idle=$((idle + 30)); fi
  if [ "$idle" -ge "$AP_TIMEOUT" ]; then
    log "no client for ${AP_TIMEOUT}s -> reboot (retry station)"; sync; reboot; exit 0
  fi
done
