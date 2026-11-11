#!/bin/sh
# CAMECRACK no-SD extras: anti-cloud hosts, wifi station (wait wlan0 + retry via
# wifi_up.sh), on-camera web config page, telnet.
CC=/etc/config/camecrack
LOG=$CC/boot.log
TP=24
log(){ echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }
log "==== extras start ===="

# --- anti-cloud: bind our hosts file over /etc/hosts ---
if [ -f "$CC/hosts" ]; then
  if mount | grep -q " on /etc/hosts "; then
    log "hosts already bound"
  else
    mount --bind "$CC/hosts" /etc/hosts 2>/dev/null && log "hosts bound"
  fi
fi

# --- PTZ without SD: ptzctl is stored xz-compressed in flash, unpacked to RAM ---
if [ -f "$CC/ptzctl.xz" ] && [ ! -x /tmp/ptzctl ]; then
  if xzcat "$CC/ptzctl.xz" > /tmp/ptzctl 2>/dev/null && chmod +x /tmp/ptzctl; then
    log "ptzctl unpacked to /tmp"
  else
    log "ptzctl unpack FAILED"; rm -f /tmp/ptzctl
  fi
fi

# Status LED: "connecting" pattern until the Wi-Fi is up (patterns in led.conf, led.sh).
[ -f "$CC/led.sh" ] && sh "$CC/led.sh" wifi_connecting

# --- wait for wlan0 (anyka_ipc loads the wifi driver on startup) ---
i=0
while [ $i -lt 60 ]; do
  [ -e /sys/class/net/wlan0 ] && break
  i=$((i+1)); sleep 1
done
if [ -e /sys/class/net/wlan0 ]; then
  log "wlan0 present after ${i}s"
else
  log "wlan0 NEVER appeared (wifi modules: $(lsmod | grep -i -c -E 'wifi|80211'))"
fi

# A real station IP only: ignore AP addresses (172.14.10.1 stock AP, 10.1.8.1 ours).
have_ip(){ ip=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p'); [ -n "$ip" ] && [ "$ip" != "172.14.10.1" ] && [ "$ip" != "10.1.8.1" ]; }

# --- no station config at all -> straight to AP (hotspot) provisioning mode ---
sta_mode=$(sed -n 's/^MODE=//p' "$CC/wifi.conf" 2>/dev/null)
n=0; ap_reason=sta-failed
if [ "$sta_mode" != "sta" ] && [ -f "$CC/ap_mode.sh" ]; then
  log "no station config (MODE=$sta_mode) -> AP mode"
  n=99; ap_reason=no-config
fi
# Long press on the reset button (recover_cfg.sh) asked for the hotspot at this boot.
if [ -f "$CC/ap_next" ] && [ -f "$CC/ap_mode.sh" ]; then
  rm -f "$CC/ap_next"; sync
  log "long press -> AP mode"
  n=99; ap_reason=long-press
fi

# --- wifi connect with retries ---
while [ $n -lt 6 ]; do
  have_ip && break
  log "wifi attempt $n"
  /bin/sh "$CC/wifi_up.sh" "$n"
  # give association + DHCP up to 20 s (checking every 2 s) before the next attempt:
  # restarting wpa_supplicant too early aborted a connection that was about to succeed.
  # Early in the boot the camera is busy and association + DHCP can take > 20 s (seen
  # 2026-11-11: the 1st attempt succeeded just after it was abandoned). Wait up to 20 s,
  # and up to 45 s while wpa_supplicant is still working (scan, association, DHCP).
  w=0; while [ $w -lt 23 ] && ! have_ip; do
    st=$(wpa_cli -iwlan0 status 2>/dev/null | sed -n "s/^wpa_state=//p")
    case "$st" in DISCONNECTED|INACTIVE|INTERFACE_DISABLED|"") [ $w -ge 10 ] && break ;; esac
    sleep 2; w=$((w+1)); done
  n=$((n+1))
done
if have_ip; then
  log "WIFI OK ip=$(ifconfig wlan0 | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')"
  [ -f "$CC/led.sh" ] && sh "$CC/led.sh" normal
  # Video overlay time zone: anyka_ipc reads /tmp/TZ ONCE at startup and only understands
  # "GMT-HH:MM" (POSIX sign: east of UTC is "-"). boot.sh copies $CC/TZ_GMT there before
  # the camera app starts; here, once the clock is synced, refresh TZ_GMT with today's
  # offset (flash written only when it changes, i.e. summer/winter time: used next boot).
  if [ -f "$CC/TZ" ]; then
    (w=0; while [ "$(date +%Y)" -lt 2024 ] && [ $w -lt 60 ]; do sleep 2; w=$((w+1)); done
     z=$(TZ="$(cat "$CC/TZ")" date +%z)                     # e.g. +0100
     case "$z" in
       [+-][0-9][0-9][0-9][0-9])
         s=-; [ "${z%????}" = "-" ] && s=+
         g="GMT$s$(echo "$z" | cut -c2-3):$(echo "$z" | cut -c4-5)"
         if [ "$(cat "$CC/TZ_GMT" 2>/dev/null)" != "$g" ]; then
           echo "$g" > "$CC/TZ_GMT"; sync
           log "overlay time zone now $g (from $(cat "$CC/TZ")): active at the next boot"
         fi ;;
     esac) &
  fi
else
  log "WIFI FAILED after $n attempts"
  # Station unusable -> hotspot + captive portal to enter a new network (ap_mode.sh).
  [ -f "$CC/ap_mode.sh" ] && setsid /bin/sh "$CC/ap_mode.sh" "$ap_reason" >/dev/null 2>&1 &
fi

# --- on-camera web config page (port 80; also the captive portal in AP mode) ---
if [ -f "$CC/webcfg.sh" ]; then
  /bin/sh "$CC/webcfg.sh" >/dev/null 2>&1 &
  log "webcfg started on :80"
fi

# --- reset button: 3 short presses => AP mode ---
[ -f "$CC/button_watch.sh" ] && /bin/sh "$CC/button_watch.sh" >/dev/null 2>&1 &

# --- telnet (passwordless root shell on port 24): OFF unless $CC/telnet_on exists ---
# The PC tool drives PTZ through the web page (/ptz), so no open shell is needed day to
# day. Enable it with TELNET=on in the SD card's liberator.conf (or insert the SD card:
# the toolkit has its own telnet). Never in AP mode (open hotspot), unless $CC/ap_telnet.
# The stock firmware also runs a telnetd on port 23 in local (factory) mode, and the SD
# toolkit left root's password as the publicly documented "telnet" in /etc/config/shadow:
# any telnetd that is not ours (-p $TP) is stopped too.
[ -f "$CC/telnet_on" ] && log "telnet ON (port $TP)" || log "telnet off"
while :; do
  for pid in $(ps | grep '[t]elnetd' | grep -v -- "-p ${TP}" | awk '{print $1}'); do
    kill "$pid" 2>/dev/null && [ ! -f /tmp/cc_tn_killed ] && { : > /tmp/cc_tn_killed; log "stock telnetd stopped (pid $pid)"; }   # log once: boot.log is in flash
  done
  if [ -f "$CC/telnet_on" ] && { [ ! -f /tmp/camecrack_ap ] || [ -f "$CC/ap_telnet" ]; }; then
    ps | grep -v grep | grep -q "telnetd -p ${TP}" || telnetd -p "${TP}" -l /bin/sh 2>/dev/null
  fi
  sleep 3
done
