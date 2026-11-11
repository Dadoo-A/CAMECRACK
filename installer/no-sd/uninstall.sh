#!/bin/sh
# CAMECRACK no-SD uninstall: restore the original sensor_driver.sh and remove hooks.
# Run this on the camera (telnet) to fully revert the no-SD persistence.
CC=/etc/config/camecrack
if [ -f "$CC/sensor_driver.sh.orig" ]; then
  cp "$CC/sensor_driver.sh.orig" /etc/config/sensor_driver.sh
  echo "sensor_driver.sh restored."
else
  echo "WARN: backup $CC/sensor_driver.sh.orig missing; edit /etc/config/sensor_driver.sh by hand."
fi
# Undo runtime binds if present (harmless if not mounted).
umount /etc/hosts 2>/dev/null
umount /etc/config/_ht_sw_settings.ini 2>/dev/null
umount /usr/local/_ht_hw_settings.ini 2>/dev/null
umount /usr/sbin/recover_cfg.sh 2>/dev/null
echo "Done. Reboot to apply. (The $CC folder is kept; 'rm -rf $CC' to remove it too.)"
