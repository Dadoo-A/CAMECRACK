#!/bin/sh
# CAMECRACK: tiny HTTP config server (nc + shell). Serves the Wi-Fi config page.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
CC=/etc/config/camecrack
PORT=80
while :; do
  nc -l -p "$PORT" -e "$CC/webcfg_handler.sh" 2>/dev/null
  usleep 20000   # re-listen at once: a 1 s pause dropped PTZ commands (stop arriving late)
done
