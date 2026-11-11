#!/bin/sh
# CAMECRACK: bring wlan0 up as station from camecrack/wifi.conf. One attempt.
#
# Does NOT source wifi.conf and does NOT use the stock /usr/sbin/station_connect.sh:
# that script wraps SSID/PSK in single quotes and re-parses them through `sh -c`, so an
# apostrophe (or $, `, \) in the SSID or password silently breaks the connection.
# We drive wpa_cli directly instead: SSID passed as hex (any byte works), PSK passed as a
# single argument (no shell re-parsing).
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
CC=/etc/config/camecrack
LOG=/tmp/sd/logs/wifi_fixed.log
CONF=/tmp/sd/custom/configs/wifi.conf; grep -q "^MODE=sta" "$CONF" 2>/dev/null || CONF=$CC/wifi.conf
log(){ echo "[$(date +%H:%M:%S)] wifi_up: $*" >> "$LOG"; }

# Read KEY=value / KEY="value" without letting the shell interpret the value.
val(){ sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -1; }
qval(){ v=$(val "$1"); case "$v" in \"*\") v=${v#\"}; v=${v%\"};; esac; printf '%s' "$v"; }

[ -f "$CONF" ] || { log "no wifi.conf"; exit 1; }
MODE=$(val MODE); SSID=$(qval SSID); PASS=$(qval PASS)
SECURITY=$(val SECURITY); DHCP=$(val DHCP)

[ "$MODE" = "sta" ] || { log "MODE=$MODE (not sta), skip"; exit 0; }
[ -n "$SSID" ] || { log "empty SSID"; exit 1; }
[ -e /sys/class/net/wlan0 ] || { log "no wlan0"; exit 1; }

killall udhcpc wpa_supplicant 2>/dev/null
ifconfig wlan0 up 2>/dev/null
mkdir -p /var/run/wpa_supplicant 2>/dev/null
printf 'ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\n' > /tmp/wpa_supplicant.conf
wpa_supplicant -B -iwlan0 -Dnl80211 -c /tmp/wpa_supplicant.conf 2>/dev/null
sleep 1

W="wpa_cli -iwlan0"
id=$($W add_network 2>/dev/null | tail -1)
hex=$(printf '%s' "$SSID" | od -An -tx1 | awk '{for(i=1;i<=NF;i++) printf "%s", $i}')
$W set_network "$id" ssid "$hex" >/dev/null
$W set_network "$id" scan_ssid 1 >/dev/null
case "$SECURITY" in
  0|1) $W set_network "$id" key_mgmt NONE >/dev/null ;;                 # open
  *)   $W set_network "$id" key_mgmt WPA-PSK >/dev/null
       $W set_network "$id" psk "\"$PASS\"" >/dev/null ;;                # WPA/WPA2
esac
$W enable_network "$id" >/dev/null
$W select_network "$id" >/dev/null

if [ "${DHCP:-1}" != "0" ]; then
  if [ -x /usr/share/udhcpc/default.script ]; then
    udhcpc -b -i wlan0 -s /usr/share/udhcpc/default.script 2>/dev/null
  else
    udhcpc -b -i wlan0 2>/dev/null
  fi
fi
log "connect issued SSID=$SSID (sec=$SECURITY, net=$id)"
exit 0
