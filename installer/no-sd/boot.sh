#!/bin/sh
# CAMECRACK no-SD boot hook. Called from /etc/config/sensor_driver.sh install().
# If a real SD card is present, do nothing: the SD toolkit handles everything.
CC=/etc/config/camecrack
LOG=$CC/boot.log

# Wait briefly for the MMC layer to report a card (modules were just insmod'd).
n=0
while [ $n -lt 3 ]; do
  [ -b /dev/mmcblk0p1 ] && exit 0
  n=$((n+1))
  sleep 1
done

# No SD card -> enable local mode from flash, BEFORE anyka_ipc starts.
# Time zone first: anyka_ipc reads /tmp/TZ once at startup for the video overlay and only
# understands "GMT-HH:MM" (TZ_GMT, computed by extras.sh / the liberator from TIMEZONE).
if [ -f "$CC/TZ_GMT" ]; then cp "$CC/TZ_GMT" /tmp/TZ 2>/dev/null
elif [ -f "$CC/TZ" ]; then cp "$CC/TZ" /tmp/TZ 2>/dev/null; fi
# Cap the log: AP mode can reboot periodically (no client -> retry station), and
# /etc/config is a tiny 256 KB jffs2 (~20 KB free once AP mode is installed) that must
# keep room for wifi.conf.
# The temp copy goes to /tmp (RAM): a temp file in the nearly-full flash could not be written,
# which left the log uncapped and a stray .tmp behind (seen 2026-11-09, flash down to 4 KB).
rm -f "$LOG.tmp"
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 4096 ]; then
  tail -c 2048 "$LOG" > /tmp/camecrack_bootlog && cat /tmp/camecrack_bootlog > "$LOG"
fi
echo "==== boot.sh no-SD mode $(date) ====" >> "$LOG"
[ -f "$CC/_ak39_factory.ini" ]  && cp "$CC/_ak39_factory.ini" /tmp/_ak39_factory.ini 2>/dev/null && echo "factory marker set" >> "$LOG"
[ -f "$CC/_ht_hw_settings.ini" ] && mount --bind "$CC/_ht_hw_settings.ini" /usr/local/_ht_hw_settings.ini 2>/dev/null && echo "hw settings bound" >> "$LOG"
[ -f "$CC/_ht_sw_settings.ini" ] && mount --bind "$CC/_ht_sw_settings.ini" /etc/config/_ht_sw_settings.ini 2>/dev/null && echo "sw settings bound" >> "$LOG"

# Custom boot jingle: bind our mp3 (8 kHz mono) over the factory-mode voice prompt
# that anyka_ipc plays at startup, so the camera says our line instead of the Chinese one.
[ -f "$CC/jingle.mp3" ] && mount --bind "$CC/jingle.mp3" /usr/share/8k16_cn_factory_enter_factory_mode.mp3 2>/dev/null && echo "jingle bound" >> "$LOG"
[ -f "$CC/bip.mp3" ] && mount --bind "$CC/bip.mp3" /usr/share/hutong_sound2.mp3 2>/dev/null && echo "bip bound" >> "$LOG"

# Reset button: neutralize the Tuya factory reset (long press), keep only our 3 short presses.
[ -f "$CC/recover_cfg.sh" ] && mount --bind "$CC/recover_cfg.sh" /usr/sbin/recover_cfg.sh 2>/dev/null && echo "tuya reset disabled" >> "$LOG"

# Extras (offline hosts, wifi station, telnet) in the background.
[ -f "$CC/extras.sh" ] && /bin/sh "$CC/extras.sh" >/dev/null 2>&1 &

exit 0
