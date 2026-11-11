#!/bin/sh
# CAMECRACK: status LED driven by events, each with a user-chosen pattern (led.conf).
#   sh led.sh <event> [seconds]        apply the event's pattern (then "normal" after N s)
#   sh led.sh --pattern <p> [seconds]  apply a pattern directly (used by the "Test" button)
# Patterns: off | on | blink:<on_ms>:<off_ms>   (50..5000 ms)
# Events:   normal wifi_connecting hotspot_starting hotspot_ready install_ok install_failed
# The camera app's own LED handling is disabled (bool_led_enable = 0): only we drive it.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
CC=/etc/config/camecrack
CONF=$CC/led.conf
L=/sys/class/leds/state_led
default() {
  case "$1" in
    hotspot_starting) echo blink:150:150 ;;
    hotspot_ready)    echo blink:1000:1000 ;;
    install_ok)       echo blink:100:100 ;;
    install_failed)   echo blink:1000:1000 ;;
    *)                echo off ;;
  esac
}
pattern_of() { p=$(sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -1); echo "${p:-$(default "$1")}"; }
valid() { case "$1" in off|on) return 0 ;; blink:[0-9]*:[0-9]*) ;; *) return 1 ;; esac
  a=${1#blink:}; b=${a#*:}; a=${a%%:*}
  case "$a$b" in *[!0-9]*) return 1 ;; esac
  [ "$a" -ge 50 ] && [ "$a" -le 5000 ] && [ "$b" -ge 50 ] && [ "$b" -le 5000 ]; }
apply() {
  case "$1" in
    on)  echo none > "$L/trigger"; echo 1 > "$L/brightness" ;;
    blink:*) a=${1#blink:}; echo timer > "$L/trigger"
             echo "${a%%:*}" > "$L/delay_on"; echo "${a#*:}" > "$L/delay_off" ;;
    *)   echo none > "$L/trigger"; echo 0 > "$L/brightness" ;;
  esac
}

# Helpers for the web page / Home Assistant API (no LED access needed).
case "$1" in
  --check) valid "$2"; exit $? ;;
  --get)   pattern_of "$2"; exit 0 ;;
esac
[ -w "$L/brightness" ] || exit 0

if [ "$1" = "--pattern" ]; then p=$2; shift 2; else p=$(pattern_of "${1:-normal}"); [ $# -gt 0 ] && shift; fi
valid "$p" || p=off
apply "$p"
# Temporary signal: back to the "normal" pattern after N seconds (in the background).
case "$1" in [0-9]*) ( sleep "$1"; n=$(pattern_of normal); valid "$n" || n=off; apply "$n" ) >/dev/null 2>&1 & ;; esac
exit 0
