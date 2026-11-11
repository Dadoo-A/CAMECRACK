#!/bin/sh
# CAMECRACK: 3 short presses on the reset button within 5 s => AP mode (Wi-Fi setup
# hotspot). The button is gpio-keys on /dev/input/event0, code 116 (KEY_POWER).
# Short presses only: the camera app may treat a LONG press (~5 s+) as a Tuya reset.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
CC=/etc/config/camecrack
LOG=$CC/boot.log
EV=/dev/input/event0
log(){ echo "[$(date +%H:%M:%S)] button: $*" >> "$LOG"; }
[ -c "$EV" ] || { log "no $EV"; exit 0; }

p1=0; p2=0; fails=0
while :; do
  # One struct input_event (16 bytes on this 32-bit kernel) per read:
  # u16 words = sec_lo sec_hi usec_lo usec_hi TYPE CODE VALUE_lo VALUE_hi
  ev=$(dd if="$EV" bs=16 count=1 2>/dev/null | od -An -tu2)
  if [ -z "$ev" ]; then
    fails=$((fails + 1)); [ "$fails" -ge 10 ] && { log "cannot read $EV, giving up"; exit 1; }
    sleep 5; continue
  fi
  set -- $ev
  [ "$5" = 1 ] && [ "$6" = 116 ] && [ "$7" = 1 ] || continue   # EV_KEY, KEY_POWER, press
  now=$(date +%s)
  if [ "$p1" -gt 0 ] && [ $((now - p1)) -le 5 ]; then
    log "3 presses -> AP mode"
    setsid /bin/sh "$CC/ap_mode.sh" button >/dev/null 2>&1 &
    p1=0; p2=0
    continue
  fi
  p1=$p2; p2=$now
done
