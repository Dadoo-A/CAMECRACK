#!/bin/sh
# CAMECRACK "liberator": installs the no-SD mode into the camera's flash by itself.
#
# Started by entrypoint.sh on every boot WITH the SD card. Steps:
#   1. checks the camera has the expected layout (otherwise touches nothing);
#   2. records the hardware (Wi-Fi chip, motors, free space);
#   3. backs up the WHOLE flash to the SD card (once per camera, MD5-checked),
#      plus a copy of /etc/config before every change;
#   4. copies into /etc/config/camecrack/ only what changed (MD5), by priority:
#      scripts+settings, PTZ, AP mode, sounds — depending on free space;
#   5. adds the boot hook LAST (an interrupted install = stock camera).
# Human-readable result on the PC: LIBERATOR-RESULT.txt at the root of the SD card.
#
# Setting (custom/configs/liberator.conf): LIBERATOR=install (default) | off | uninstall
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

SD=/tmp/sd
SRC=$SD/camecrack               # copy of installer/no-sd (prepare-sd.ps1)
CFG=$SD/custom/configs
CC=/etc/config/camecrack
HOOK_TAG="CAMECRACK no-SD persistence hook"
MARGIN=2048                     # bytes always left free in /etc/config (jffs2 keeps its own reserve)
LOG=$SD/logs/liberator.log
RES=$SD/LIBERATOR-RESULT.txt

mkdir -p "$SD/logs"
rm -f "$SD/LIBERATEUR-RESULTAT.txt"   # result file name of the first (French) version
exec >>"$LOG" 2>&1
log() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*"; }
result() { # final state, readable by a human, at the root of the card
  { echo "CAMECRACK liberator - $(date)"; echo "Result: $1"; echo "Details: logs/liberator.log";
    [ -f /tmp/cc_hw ] && { echo; cat /tmp/cc_hw; }; } > "$RES"
  log "RESULT: $1"; sync
  # Visible signal on the camera's status LED (no audio player usable from a script):
  # OK/UNINSTALLED = fast blink for 15 s, anything else = slow blink for 30 s.
  # Uses the patterns chosen by the user (led.sh + led.conf) when installed, else built-in ones.
  if [ -f "$CC/led.sh" ]; then
    case "$1" in OK*|UNINSTALLED*) sh "$CC/led.sh" install_ok 15 ;; *) sh "$CC/led.sh" install_failed 30 ;; esac
  else
    case "$1" in OK*|UNINSTALLED*) led_signal 100 150 ;; *) led_signal 1000 15 ;; esac
  fi
}
led_signal() { # led_signal <half-period ms> <times>
  L=/sys/class/leds/state_led
  [ -w "$L/brightness" ] || return 0
  ( prev=$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$L/trigger"); echo none > "$L/trigger"
    i=0; while [ $i -lt "$2" ]; do
      echo 1 > "$L/brightness"; usleep $(($1 * 1000)); echo 0 > "$L/brightness"; usleep $(($1 * 1000))
      i=$((i+1)); done
    echo "${prev:-none}" > "$L/trigger"; echo 0 > "$L/brightness" ) >/dev/null 2>&1 &   # stealth: LED off
}
md5() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }
size() { if [ -f "$1" ]; then wc -c < "$1"; else echo 0; fi; }
free_b() { df /etc/config 2>/dev/null | awk 'END{print $(NF-2)*1024}'; }

[ -f /tmp/camecrack_liberator.done ] && exit 0      # once per boot
: > /tmp/camecrack_liberator.done
log "==== liberator start ===="

LIBERATOR=install
TELNET=off
WEB_PASSWORD=""
TIMEZONE=""
[ -f "$CFG/liberator.conf" ] && . "$CFG/liberator.conf"
log "mode=$LIBERATOR"
[ "$LIBERATOR" = "off" ] && { result "OFF (liberator.conf: LIBERATOR=off), nothing done"; exit 0; }

# ---------- 1. expected layout ----------
bad=""
[ -f /etc/config/sensor_driver.sh ] || bad="$bad sensor_driver.sh"
grep -q "sensor_driver.sh" /usr/sbin/main.sh 2>/dev/null || bad="$bad main.sh-hook"
[ -x /usr/bin/anyka_ipc ] || bad="$bad anyka_ipc"
grep -q " /etc/config jffs2 rw" /proc/mounts || bad="$bad /etc/config-rw"
if [ -n "$bad" ]; then
  result "REFUSED: camera not recognized (missing:$bad). Nothing was modified."
  exit 1
fi

# ---------- 2. hardware ----------
MAC=$(cat /sys/class/net/wlan0/address 2>/dev/null | sed 's/://g')
[ -n "$MAC" ] || MAC=unknown
WIFI=$(lsmod 2>/dev/null | awk '{print $1}' | grep -i -m1 -E 'atbm|ssv|rtl|8188|mt76|xr8|aic')
{
  echo "Hardware:"
  echo "  MAC           : $MAC"
  echo "  SoC           : $(grep -i -m1 -E 'Hardware|model name' /proc/cpuinfo | sed 's/.*: //')"
  echo "  Kernel        : $(uname -r)"
  echo "  Wi-Fi module  : ${WIFI:-unknown}"
  echo "  PTZ motors    : $([ -c /dev/motor0 ] && echo yes || echo no)"
  echo "  anyka_ipc md5 : $(md5 /usr/bin/anyka_ipc)"
  echo "  /etc/config   : $(($(free_b)/1024)) KB free"
  echo "  Telnet (port 24): $TELNET"
} > /tmp/cc_hw
cat /tmp/cc_hw
case "$WIFI" in
  ATBM*|atbm*) ;;
  *) log "WARN: untested Wi-Fi chip ($WIFI): AP mode (hostapd 2.8) may not work" ;;
esac

# ---------- uninstall ----------
if [ "$LIBERATOR" = "uninstall" ]; then
  if [ -f "$CC/sensor_driver.sh.orig" ]; then
    cp "$CC/sensor_driver.sh.orig" /etc/config/sensor_driver.sh && rm -rf "$CC" && sync
    result "UNINSTALLED: hook removed and /etc/config/camecrack deleted. Set LIBERATOR=install to reinstall."
  else
    result "nothing to uninstall (no sensor_driver.sh.orig)"
  fi
  exit 0
fi

[ -d "$SRC" ] || { result "FAILED: camecrack/ folder missing on the SD card (run prepare-sd.ps1 again)"; exit 1; }

# ---------- 3. full flash backup (once per camera) ----------
BK=$SD/backup/$MAC
mkdir -p "$BK"
grep '^mtd' /proc/mtd > "$BK/mtd.txt"
while read -r dev sz _ name; do
  n=${dev%:}; f="$BK/$n.bin"; want=$((0x$sz))
  if [ "$(size "$f")" = "$want" ] && grep -q " $n.bin\$" "$BK/md5.txt" 2>/dev/null; then continue; fi
  log "backup $n $name ($want bytes)"
  # CONFIG (live jffs2) may change between the copy and the check: 3 tries
  t=0; a=x; b=y
  while [ $t -lt 3 ] && { [ "$(size "$f")" != "$want" ] || [ "$a" != "$b" ]; }; do
    dd if=/dev/$n of="$f" bs=4096 2>/dev/null; sync
    a=$(md5 "$f"); b=$(md5 /dev/$n); t=$((t+1))
  done
  if [ "$(size "$f")" != "$want" ] || [ "$a" != "$b" ]; then
    rm -f "$f"; result "FAILED: backup of $n is invalid (SD card full?). Nothing was modified."; exit 1
  fi
  grep -v " $n.bin\$" "$BK/md5.txt" 2>/dev/null > /tmp/cc_md5; echo "$a  $n.bin" >> /tmp/cc_md5
  cat /tmp/cc_md5 > "$BK/md5.txt"
done < "$BK/mtd.txt"
sync
log "flash backup OK in backup/$MAC"

# ---------- 4. what needs copying? ----------
# "source|destination" by priority. Settings come from the toolkit's SD config.
LIST="
$SRC/boot.sh|boot.sh
$SRC/extras.sh|extras.sh
$SRC/wifi_up.sh|wifi_up.sh
$SRC/webcfg.sh|webcfg.sh
$SRC/webcfg_handler.sh|webcfg_handler.sh
$SRC/ap_mode.sh|ap_mode.sh
$SRC/button_watch.sh|button_watch.sh
$SRC/uninstall.sh|uninstall.sh
$SRC/recover_cfg.sh|recover_cfg.sh
$SRC/led.sh|led.sh
$SD/_ak39_factory.ini|_ak39_factory.ini
$CFG/_ht_hw_settings.ini|_ht_hw_settings.ini
$CFG/_ht_sw_settings.ini|_ht_sw_settings.ini
$CFG/hosts|hosts
$CFG/ptz.conf|ptz.conf
@ptz
$SRC/ptzctl.xz|ptzctl.xz
@ap
$SRC/ap-bin.tar.xz|ap-bin.tar.xz
@sounds
$SRC/jingle.mp3|jingle.mp3
$SRC/bip.mp3|bip.mp3
"

# The SD wifi.conf is only installed if the flash has none, or if the card's one changed
# since the last install (otherwise we would overwrite a change made through the web page).
WIFI_SD=""
if [ -f "$CFG/wifi.conf" ] && [ -n "$(sed -n 's/^SSID=//p' "$CFG/wifi.conf" | sed 's/["'\'' ]//g')" ]; then
  if [ ! -f "$CC/wifi.conf" ] || [ "$(md5 "$CFG/wifi.conf")" != "$(cat "$CC/.sd_wifi.md5" 2>/dev/null)" ]; then
    WIFI_SD=1
  fi
fi

# Sounds can be changed from the PC tool (camera web page /sound): the SD card copy only
# replaces the camera one when it changed on the card since it was last installed.
skip_sound() { # skip_sound <src> <name>: 0 = keep the camera's own sound
  case "$2" in jingle.mp3|bip.mp3) ;; *) return 1 ;; esac
  [ -f "$CC/$2" ] || return 1
  r="$CC/.sd_$2.md5"; m=$(md5 "$1")
  [ -f "$r" ] || { echo "$m" > "$r"; return 0; }   # first time: trust the camera
  [ "$(cat "$r")" = "$m" ]
}

changes=0
for e in $LIST; do case "$e" in @*) ;; *) s=${e%%|*}; d=${e##*|}
  [ -f "$s" ] && ! skip_sound "$s" "$d" && [ "$(md5 "$s")" != "$(md5 "$CC/$d")" ] && changes=$((changes+1)); esac; done
[ -n "$WIFI_SD" ] && [ "$(md5 "$CFG/wifi.conf")" != "$(md5 "$CC/wifi.conf")" ] && changes=$((changes+1))
hooked=0; grep -q "$HOOK_TAG" /etc/config/sensor_driver.sh && hooked=1

# Telnet (passwordless root shell, port 24) only when asked: TELNET=on in liberator.conf.
set_telnet() {
  [ -d "$CC" ] || return 0
  if [ "$TELNET" = "on" ]; then [ -f "$CC/telnet_on" ] || { : > "$CC/telnet_on"; sync; log "telnet enabled"; }
  else [ -f "$CC/telnet_on" ] && { rm -f "$CC/telnet_on"; sync; log "telnet disabled"; }; fi
}

# Password of the camera web page (Wi-Fi settings + /ptz): HTTP Basic, user "admin".
# Stored as base64("admin:<password>") in $CC/web_auth; empty WEB_PASSWORD = no password.
b64() { LC_ALL=C awk -v s="$1" 'BEGIN{b="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  for(i=1;i<256;i++) o[sprintf("%c",i)]=i; n=length(s); r=""
  for(i=1;i<=n;i+=3){a=o[substr(s,i,1)]; c=(i+1<=n)?o[substr(s,i+1,1)]:0; d=(i+2<=n)?o[substr(s,i+2,1)]:0
    t=a*65536+c*256+d; r=r substr(b,int(t/262144)+1,1) substr(b,int(t/4096)%64+1,1)
    x=(i+1<=n)?substr(b,int(t/64)%64+1,1):"="; y=(i+2<=n)?substr(b,t%64+1,1):"="; r=r x y}
  printf "%s", r}'; }
set_web_auth() {
  [ -d "$CC" ] || return 0
  if [ -n "$WEB_PASSWORD" ]; then
    v=$(b64 "admin:$WEB_PASSWORD")
    [ "$(cat "$CC/web_auth" 2>/dev/null)" = "$v" ] || { printf "%s" "$v" > "$CC/web_auth"; sync; log "web password set"; }
  else
    [ -f "$CC/web_auth" ] && { rm -f "$CC/web_auth"; sync; log "web password removed"; }
  fi
}
# Time zone (POSIX TZ string, read by uClibc from /etc/TZ -> /tmp/TZ): without it the
# camera shows UTC. boot.sh copies $CC/TZ to /tmp/TZ before the camera app starts.
set_tz() {
  [ -d "$CC" ] || return 0
  if [ -n "$TIMEZONE" ]; then
    [ "$(cat "$CC/TZ" 2>/dev/null)" = "$TIMEZONE" ] || { echo "$TIMEZONE" > "$CC/TZ"; sync; log "time zone set: $TIMEZONE"; }
    echo "$TIMEZONE" > /tmp/TZ
    # anyka_ipc's overlay only understands "GMT-HH:MM": precompute today's offset (the clock
    # is synced in SD mode) so the first no-SD boot already shows local time.
    if [ "$(date +%Y)" -ge 2024 ]; then
      z=$(TZ="$TIMEZONE" date +%z)
      case "$z" in [+-][0-9][0-9][0-9][0-9])
        s=-; [ "${z%????}" = "-" ] && s=+
        g="GMT$s$(echo "$z" | cut -c2-3):$(echo "$z" | cut -c4-5)"
        [ "$(cat "$CC/TZ_GMT" 2>/dev/null)" = "$g" ] || { echo "$g" > "$CC/TZ_GMT"; sync; log "overlay time zone: $g"; } ;;
      esac
    fi
  else
    [ -f "$CC/TZ" ] && { rm -f "$CC/TZ" "$CC/TZ_GMT"; sync; log "time zone removed (UTC)"; }
  fi
}
set_telnet; set_web_auth; set_tz

if [ "$changes" = 0 ] && [ "$hooked" = 1 ]; then
  result "OK: already up to date, nothing to do. Remove the SD card and reboot for no-SD mode."
  exit 0
fi
log "$changes file(s) to update, hook=$hooked"

# copy of /etc/config before any change
T="$BK/etc_config.$(date +%Y%m%d_%H%M%S).tar"
if ! tar -cf "$T" -C /etc config 2>/dev/null; then
  rm -f "$T"; result "FAILED: could not back up /etc/config to the SD card. Nothing was modified."; exit 1
fi
log "etc/config saved to ${T#$SD/}"

mkdir -p "$CC"
put() { # put <source> <name>: verified, atomic copy; returns 1 = not enough space
  s=$1; d=$CC/$2
  [ "$(md5 "$s")" = "$(md5 "$d")" ] && return 0
  need=$(size "$s"); old=$(size "$d")
  # balance afterwards = free - new + old (the old file is replaced)
  if [ $(( $(free_b) - need + old )) -lt $MARGIN ] && [ -f /etc/config/tuya_user.db_bak ]; then
    log "space: removing tuya_user.db_bak (copy in $T)"
    rm -f /etc/config/tuya_user.db_bak; sync
  fi
  if [ $(( $(free_b) - need + old )) -lt $MARGIN ]; then log "SKIP $2: not enough space ($(free_b) free, $need needed)"; return 1; fi
  # no room for old + new at the same time: remove the old one first, but keep a copy in
  # RAM to put it back if the write fails (jffs2 free space is only an estimate: on
  # 2026-11-11 the copy failed after the old wifi_up.sh was removed).
  rm -f /tmp/cc_old
  if [ $(( $(free_b) - need )) -lt $MARGIN ] && [ -f "$d" ]; then
    cp "$d" /tmp/cc_old && rm -f "$d" && sync
  fi
  cp "$s" "$d.new" 2>/dev/null; sync
  if [ "$(md5 "$s")" != "$(md5 "$d.new")" ]; then
    rm -f "$d.new"; sync
    [ -f /tmp/cc_old ] && cp /tmp/cc_old "$d" && sync && log "kept the previous $2"
    log "ERROR copying $2 ($(free_b) bytes free)"; return 1
  fi
  mv "$d.new" "$d"; case "$2" in *.sh) chmod 755 "$d" ;; esac
  log "installed $2"
}

tier=base; skipped=""
for e in $LIST; do
  case "$e" in
    @*) tier=${e#@} ;;
    *) s=${e%%|*}; d=${e##*|}
       [ -f "$s" ] || { log "missing on the SD card: $s"; [ "$tier" = base ] && case "$d" in *.sh) result "FAILED: $s missing on the SD card"; exit 1;; esac; continue; }
       skip_sound "$s" "$d" && continue
       if ! put "$s" "$d"; then
         [ "$tier" = base ] && { result "FAILED: not enough space for the essentials ($d). Hook not installed, camera unchanged at boot."; exit 1; }
         skipped="$skipped $tier"
       else case "$d" in jingle.mp3|bip.mp3) md5 "$s" > "$CC/.sd_$d.md5" ;; esac
       fi ;;
  esac
done
if [ -n "$WIFI_SD" ]; then
  if put "$CFG/wifi.conf" wifi.conf; then md5 "$CFG/wifi.conf" > "$CC/.sd_wifi.md5"; else result "FAILED: not enough space for wifi.conf"; exit 1; fi
fi
[ -f "$CC/wifi.conf" ] || log "WARN: no wifi.conf: without the SD card the camera will start in AP (hotspot) mode"

# ---------- 5. hook last ----------
if [ "$hooked" = 0 ]; then
  [ -f "$CC/sensor_driver.sh.orig" ] || cp /etc/config/sensor_driver.sh "$CC/sensor_driver.sh.orig"
  cat >> /etc/config/sensor_driver.sh <<'EOF'

# --- CAMECRACK no-SD persistence hook (appended, revert via camecrack/uninstall.sh) ---
if [ "$1" = "install" ] || [ $# -eq 0 ]; then
    [ -x /etc/config/camecrack/boot.sh ] && /bin/sh /etc/config/camecrack/boot.sh
fi
# --- end CAMECRACK ---
EOF
  if ! sh -n /etc/config/sensor_driver.sh; then
    cp "$CC/sensor_driver.sh.orig" /etc/config/sensor_driver.sh
    sync; result "FAILED: invalid hook, sensor_driver.sh restored"; exit 1
  fi
  log "hook added"
fi
sync
set_telnet; set_web_auth; set_tz
echo "liberator $(date +%Y%m%d)" > "$CC/VERSION"; sync

msg="OK: no-SD mode installed/updated ($changes file(s)). Remove the SD card and reboot."
[ -n "$skipped" ] && msg="$msg Not installed for lack of space:$skipped."
result "$msg"
exit 0
