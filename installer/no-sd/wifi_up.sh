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
LOG=$CC/boot.log
CONF=$CC/wifi.conf
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

# On a retry (not the 1st attempt: an explicit scan right after wpa_supplicant starts made
# the ATBM chip slow to associate, ~1 min lost at boot) scan and fix the phone-keyboard trap
# (curly apostrophe typed for a straight one, or the reverse); log 5 GHz-only networks.
# wpa_cli prints non-ASCII SSID bytes escaped, e.g. ’ as the text \xe2\x80\x99.
RQ=$(printf '\342\200\231')
if [ "${1:-0}" -ge 1 ]; then
$W scan >/dev/null 2>&1; sleep 4
$W scan_results 2>/dev/null | awk -F'\t' 'NR>1 && NF>=5 {print $2 "\t" $5}' > /tmp/cc_scan
want=$(printf '%s' "$SSID" | sed "s/$RQ/'/g")
# fx() turns the escaped text \xe2\x80\x99 back into a straight ' (pattern built with
# sprintf: awk string escapes for \x differ between implementations).
match=$(awk -F'\t' -v s="$want" 'function fx(v, t,i){t=sprintf("%cxe2%cx80%cx99",92,92,92)
  while((i=index(v,t))>0) v=substr(v,1,i-1) sprintf("%c",39) substr(v,i+12); return v}
  fx($2)==s {print $1 "\t" $2}' /tmp/cc_scan | sort -n | head -1)
seen=${match%%"	"*}; raw=${match#*"	"}
if [ -z "$match" ]; then
  log "SSID not seen in scan ($(wc -l < /tmp/cc_scan) networks): check spelling / 2.4 GHz"
else
  [ "$seen" -gt 4900 ] && log "SSID only seen on 5 GHz ($seen MHz): the camera needs 2.4 GHz"
  case "$raw" in
    *'\xe2\x80\x99'*) fixed=$(printf '%s' "$want" | sed "s/'/$RQ/g") ;;
    *) fixed=$want ;;
  esac
  [ "$fixed" != "$SSID" ] && { log "apostrophe fixed to match the network seen in scan"; SSID=$fixed; }
fi
fi   # retry-only scan

# The password can't be checked by a scan: on odd attempts (extras.sh passes the attempt
# number) try it with the other apostrophe (’ <-> '), same phone-keyboard trap.
case "$PASS" in
  *"'"*|*"$RQ"*)
    if [ $(( ${1:-0} % 2 )) = 1 ]; then
      case "$PASS" in
        *"$RQ"*) PASS=$(printf '%s' "$PASS" | sed "s/$RQ/'/g") ;;
        *)       PASS=$(printf '%s' "$PASS" | sed "s/'/$RQ/g") ;;
      esac
      log "attempt $1: password tried with the other apostrophe"
    fi ;;
esac

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
