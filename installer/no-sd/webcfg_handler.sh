#!/bin/sh
# CAMECRACK: HTTP request handler (stdin=request, stdout=response). Run via nc -e.
# nc -e execs us with an empty environment, so set PATH for busybox applets.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
CC=/etc/config/camecrack

read -r method path proto
# Drain the rest of the request headers so the socket closes cleanly on our side
# (otherwise unread input makes the kernel send RST and the client loses our reply).
CR=$(printf '\r')
auth=""; clen=0
while read -r h; do
  h=${h%"$CR"}
  [ -z "$h" ] && break
  case "$h" in
    [Aa]uthorization:*) auth=${h#*: } ;;
    [Cc]ontent-[Ll]ength:*) clen=${h#*: } ;;
  esac
done
case "$path" in *\?*) qs="${path#*\?}"; path="${path%%\?*}";; *) qs="";; esac

# Password (HTTP Basic, user "admin"): set when $CC/web_auth exists (base64 of
# "admin:<password>", written by the liberator from WEB_PASSWORD in liberator.conf).
# Not asked in hotspot mode: it was started by a physical button press or a failed
# Wi-Fi, and phone captive-portal browsers handle Basic auth badly.
if [ -s "$CC/web_auth" ] && [ ! -f /tmp/camecrack_ap ] && [ "$auth" != "Basic $(cat "$CC/web_auth")" ]; then
  printf 'HTTP/1.0 401 Unauthorized\r\nWWW-Authenticate: Basic realm="CAMECRACK"\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nPassword required (user: admin).\n'
  exit 0
fi

# NB: 'tr' is NOT available on this firmware; use awk/sed only.
field(){ echo "$qs" | awk -v k="$1" 'BEGIN{RS="&"} {p=index($0,"="); if(p>0 && substr($0,1,p-1)==k){print substr($0,p+1); exit}}'; }
urldec(){ printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%\(..\)/\\x\1/g')"; }
send(){ printf 'HTTP/1.0 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n%s' "$1"; }

if [ "$path" = "/sound" ] && [ "$method" = "POST" ]; then
  # Replace the boot jingle or the beep: raw MP3 body (8 kHz mono, prepared by the PC
  # tool), max 24 KB, applied at the next boot (boot.sh binds it over the stock sound).
  name=$(field name)
  case "$name" in jingle|bip) ;; *) name="" ;; esac
  case "$clen" in ""|*[!0-9]*) clen=0 ;; esac
  err=""
  [ -n "$name" ] || err="name must be jingle or bip"
  [ -z "$err" ] && { [ "$clen" -gt 0 ] && [ "$clen" -le 24576 ]; } || err="${err:-size must be 1..24576 bytes}"
  if [ -z "$err" ]; then
    head -c "$clen" > /tmp/cc_sound
    magic=$(head -c 3 /tmp/cc_sound | od -An -tx1 | sed "s/ //g")
    case "$magic" in 494433*|fff*) ;; *) err="not an MP3 file" ;; esac
    [ "$(wc -c < /tmp/cc_sound)" = "$clen" ] || err="${err:-incomplete upload}"
  fi
  if [ -z "$err" ]; then
    old=0; [ -f "$CC/$name.mp3" ] && old=$(wc -c < "$CC/$name.mp3")
    free=$(df /etc/config | awk 'END{print $(NF-2)*1024}')
    [ $((free - clen + old)) -ge 8192 ] || err="not enough flash space ($free bytes free)"
  fi
  if [ -z "$err" ]; then
    cp /tmp/cc_sound "$CC/$name.mp3.new" && sync && mv "$CC/$name.mp3.new" "$CC/$name.mp3" && sync || err="write failed"
    rm -f "$CC/$name.mp3.new"
  fi
  rm -f /tmp/cc_sound
  if [ -z "$err" ]; then
    echo "[$(date +%H:%M:%S)] webcfg: new $name.mp3 ($clen bytes), active at next boot" >> "$CC/boot.log"
    printf 'HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{"ok":true,"name":"%s","bytes":%s}' "$name" "$clen"
  else
    printf 'HTTP/1.0 400 Bad Request\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{"ok":false,"error":"%s"}' "$err"
  fi
elif [ "$path" = "/led" ]; then
  # Status LED per event (stored on the camera in led.conf, so any client - PC tool or
  # Home Assistant - sees and keeps the same settings).
  #   GET /led                                  -> all events and their patterns (JSON)
  #   GET /led?event=E&pattern=P                -> save (and apply now if E=normal)
  #   GET /led?pattern=P&test=1                 -> show P for 5 s, then back to normal
  # P = off | on | blink:<on_ms>:<off_ms> (50..5000)
  EVENTS="normal wifi_connecting hotspot_starting hotspot_ready install_ok install_failed"
  event=$(field event); pat=$(urldec "$(field pattern)"); err=""
  if [ -n "$pat" ]; then
    sh "$CC/led.sh" --check "$pat" || err="pattern must be off, on or blink:<on_ms>:<off_ms> (50..5000)"
    if [ -z "$err" ] && [ "$(field test)" = "1" ]; then
      sh "$CC/led.sh" --pattern "$pat" 5
    elif [ -z "$err" ]; then
      case " $EVENTS " in *" $event "*) ;; *) err="unknown event" ;; esac
      if [ -z "$err" ] && [ "$(sh "$CC/led.sh" --get "$event")" != "$pat" ]; then
        { grep -v "^$event=" "$CC/led.conf" 2>/dev/null; echo "$event=$pat"; } > /tmp/cc_led
        cat /tmp/cc_led > "$CC/led.conf"; rm -f /tmp/cc_led; sync
      fi
      [ -z "$err" ] && [ "$event" = "normal" ] && sh "$CC/led.sh" normal
    fi
  fi
  if [ -n "$err" ]; then
    printf 'HTTP/1.0 400 Bad Request\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{"ok":false,"error":"%s"}' "$err"
  else
    j=""; for e in $EVENTS; do j="$j${j:+,}\"$e\":\"$(sh "$CC/led.sh" --get "$e")\""; done
    printf 'HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{"ok":true,"led":{%s}}' "$j"
  fi
elif [ "$path" = "/log" ]; then
  # Read the no-SD boot log without the SD card or telnet (password-protected like the rest).
  printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n'
  echo "uptime: $(cut -d' ' -f1 /proc/uptime) s   date: $(date)   load: $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "video clients (RTSP :554):"; netstat -tn 2>/dev/null | grep ":554 " | awk '{print "  " $5 "  send-queue " $3}'
  top -b -n1 2>/dev/null | sed -n '2p;5,8p'
  echo "---- boot.log"
  tail -c 4096 "$CC/boot.log" 2>/dev/null
elif [ "$path" = "/ptz" ]; then
  # PTZ for the PC tool, so it no longer needs a root shell (telnet). Only a fixed set
  # of directions and a numeric speed are accepted; nothing else can be run from here.
  dir=$(field dir); speed=$(field speed)
  case "$speed" in [0-9]|[0-9].[0-9]|[0-9].[0-9][0-9]) ;; *) speed=0.6 ;; esac
  P=/tmp/ptzctl; C=$CC/ptz.conf
  [ -x "$P" ] || { P=/tmp/sd/custom/bin/ptzctl; C=/tmp/sd/custom/configs/ptz.conf; }
  ok=true
  # rel=dx,dy : relative move of both axes at once (ptzctl -J), each in -1..1
  # (pan: 1 = 180 degrees, tilt: 1 = 98 degrees). Used by the PC tracking (continuous).
  rel=$(urldec "$(field rel)")
  if [ -n "$rel" ]; then
    case "$rel" in
      *[!0-9.,-]*|*,*,*|,*|*,) dir="" ;;
      *,*) dir=rel ;;
      *) dir="" ;;
    esac
  fi
  # cont=1 : continuous move (ptzctl CONTINUOUS_MODE: small motor steps every 80 ms) that
  # replaces the previous one; it stops by itself after 2 s unless renewed (PC app crash safety).
  PID=/tmp/cc_ptz_cont.pid
  stop_cont(){ [ -f $PID ] && kill "$(cat $PID)" 2>/dev/null; rm -f $PID; }
  if [ "$(field cont)" = "1" ]; then
    case "$dir" in
      up|down|left|right)
        [ -f /tmp/cc_ptz_cont.conf ] || sed 's/^CONTINUOUS_MODE=.*/CONTINUOUS_MODE=1/' "$C" > /tmp/cc_ptz_cont.conf
        stop_cont
        "$P" -c /tmp/cc_ptz_cont.conf -m "$dir" -s "$speed" >/dev/null 2>&1 &
        pid=$!; echo $pid > $PID
        ( sleep 2; [ "$(cat $PID 2>/dev/null)" = "$pid" ] && { kill $pid; rm -f $PID; } ) >/dev/null 2>&1 &
        dir="cont-$dir" ;;
    esac
  fi
  [ "$dir" = "stop" ] && stop_cont
  case "$dir" in
    cont-*) ;;
    rel) "$P" -c "$C" -J "$rel,0" >/dev/null 2>&1 & ;;
    up|down|left|right) "$P" -c "$C" -m "$dir" -s "$speed" >/dev/null 2>&1 & ;;
    stop) "$P" -c "$C" -m stop >/dev/null 2>&1 & ;;
    home) "$P" -c "$C" -h >/dev/null 2>&1 & ;;
    *) ok=false; dir="" ;;
  esac
  [ -x "$P" ] || ok=false
  printf 'HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{"ok":%s,"dir":"%s"}' "$ok" "$dir"
elif [ "$path" = "/save" ]; then
  ssid=$(urldec "$(field ssid)")
  pass=$(urldec "$(field pass)")
  sec=$(field sec); [ -z "$sec" ] && sec=3
  if [ -n "$ssid" ]; then
    cp -f "$CC/wifi.conf" "$CC/wifi.conf.bak" 2>/dev/null
    printf 'MODE=sta\nSSID="%s"\nPASS="%s"\nSECURITY=%s\nDHCP=1\n' "$ssid" "$pass" "$sec" > "$CC/wifi.conf.new" && mv "$CC/wifi.conf.new" "$CC/wifi.conf"
    if [ -f /tmp/camecrack_ap ]; then
      # Hotspot mode: the driver cannot switch AP->station hot -> reboot into station.
      send "<meta name=viewport content='width=device-width,initial-scale=1'><body style='font-family:sans-serif;max-width:430px;margin:24px auto;padding:0 12px'><h2>OK</h2><p>Wi-Fi saved: <b>$ssid</b>.<br>The camera reboots and joins this network (~1 min). The CAMECRACK hotspot will disappear: reconnect your phone to your usual Wi-Fi.</p></body>"
      echo "[$(date +%H:%M:%S)] webcfg: new wifi '$ssid' saved in AP mode -> reboot" >> "$CC/boot.log"
      ( sleep 3; sync; reboot ) >/dev/null 2>&1 &
    else
      send "<meta name=viewport content='width=device-width,initial-scale=1'><body style='font-family:sans-serif;max-width:430px;margin:24px auto;padding:0 12px'><h2>OK</h2><p>Wi-Fi saved: <b>$ssid</b>.<br>The camera reconnects in 3 s. If its IP changes, look for it on your router.</p></body>"
      ( sleep 3; /bin/sh "$CC/wifi_up.sh" ) >/dev/null 2>&1 &
    fi
  else
    send "<body style='font-family:sans-serif'><h2>Error</h2><p>Empty SSID. <a href='/'>back</a></p></body>"
  fi
else
  cur=""
  [ -f "$CC/wifi.conf" ] && cur=$(sed -n 's/^SSID=//p' "$CC/wifi.conf" | sed 's/"//g')
  send "<meta name=viewport content='width=device-width,initial-scale=1'><title>CAMECRACK Wi-Fi</title><body style='font-family:sans-serif;max-width:430px;margin:24px auto;padding:0 12px'><h2>CAMECRACK &mdash; Wi-Fi</h2><p>Current network: <b>$cur</b></p><form action='/save' method='get'><p>SSID<br><input name='ssid' value=\"$cur\" style='width:100%;padding:8px;box-sizing:border-box'></p><p>Password<br><input name='pass' type='password' style='width:100%;padding:8px;box-sizing:border-box'></p><p>Security <select name='sec'><option value='3'>WPA/WPA2</option><option value='0'>Open</option></select></p><button style='padding:10px 16px'>Save &amp; reconnect</button></form></body>"
fi
