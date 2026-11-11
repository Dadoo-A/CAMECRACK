#!/bin/bash
# CAMECRACK: build a STATIC hostapd 2.8 for the Anyka AK3918EV330 (ARM926EJ-S, ARMv5TE,
# soft-float EABI), linked against musl so it needs nothing from the camera's uClibc.
#
# Runs inside a throwaway Debian container (see build-hostapd.ps1):
#   docker run --rm -v <this dir>:/recipe:ro -v <out>:/out debian:bookworm bash /recipe/build-hostapd.sh
# Output: /out/hostapd (stripped), /out/hostapd.xz (what goes to flash), /out/SHA256SUMS
set -euo pipefail

MUSL_VER=1.2.5
HOSTAPD_VER=2.8
HOSTAPD_SHA256=929f522be6eeec38c53147e7bc084df028f65f148a3f7e4fa6c4c3f955cee4b0
LIBNL_TINY_COMMIT=${LIBNL_TINY_COMMIT:-master}
CROSS=arm-linux-gnueabi-          # Debian armel = ARMv5TE baseline, soft-float EABI
ARCHFLAGS="-march=armv5te -mtune=arm926ej-s -marm -mfloat-abi=soft"
# xz for the camera's busybox xzcat (xz-embedded): an EXPLICIT small dictionary (xz -9
# declares 64 MiB when it cannot see the input size, e.g. from a pipe, and the 32 MB
# camera then fails with "corrupted data"); crc32 check; NO BCJ filter (unsupported).
XZ="xz --check=crc32 --lzma2=preset=9e,dict=256KiB"
OPT="-Os -ffunction-sections -fdata-sections -fno-asynchronous-unwind-tables"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi linux-libc-dev-armel-cross make curl ca-certificates git xz-utils file >/dev/null

W=/build; rm -rf $W; mkdir -p $W; cd $W

# --- 1. musl, cross-built with the armel gcc -------------------------------------------
curl -sSfL https://musl.libc.org/releases/musl-$MUSL_VER.tar.gz | tar xz
( cd musl-$MUSL_VER
  CC=${CROSS}gcc CFLAGS="$ARCHFLAGS -Os" ./configure --target=arm-linux-gnueabi \
     --prefix=/opt/musl --disable-shared --enable-wrapper=gcc >/dev/null
  make -j"$(nproc)" >/dev/null && make install >/dev/null )
# musl ships no kernel UAPI headers: take ONLY linux/ asm/ asm-generic/ from Debian's
# armel cross headers (never the glibc ones next to them).
KH=/usr/arm-linux-gnueabi/include
cp -r $KH/linux $KH/asm $KH/asm-generic /opt/musl/include/
MCC="/opt/musl/bin/musl-gcc"
export REALGCC=${CROSS}gcc
echo "musl OK: $($MCC -dumpmachine)"

# --- 2. libnl-tiny (OpenWrt) as a static lib --------------------------------------------
git clone -q https://git.openwrt.org/project/libnl-tiny.git
( cd libnl-tiny && git checkout -q "$LIBNL_TINY_COMMIT" && echo "libnl-tiny @ $(git rev-parse --short HEAD)"
  for f in *.c; do $MCC $ARCHFLAGS $OPT -Iinclude -D_GNU_SOURCE -c "$f" -o "${f%.c}.o"; done
  ${CROSS}ar rcs libnl-tiny.a *.o )
NL=$W/libnl-tiny

# --- 3. hostapd 2.8 ---------------------------------------------------------------------
curl -sSfLO https://w1.fi/releases/hostapd-$HOSTAPD_VER.tar.gz
echo "$HOSTAPD_SHA256  hostapd-$HOSTAPD_VER.tar.gz" | sha256sum -c -
tar xzf hostapd-$HOSTAPD_VER.tar.gz

# Two variants from the same sources:
#   debug : stock upstream code + hostapd-2.8.config (stdout debug -dd, ctrl socket, 11n).
#           Field diagnosis only: pushed to /tmp over the network, NEVER stored in flash.
#   flash : what goes to /etc/config (xz). Open-AP only:
#           - no debug strings, no ctrl socket, no 802.11n (legacy g is plenty for a portal)
#           - station/P2P/TDLS/mesh/scan/ACS/DFS entries removed from the nl80211 ops
#             table (hostapd NULL-checks every op), so gc/LTO can drop that code
#           - security stack (WPA authenticator, 802.1X/EAPOL, EAP server, crypto) left
#             out of the link and replaced by open_ap_stubs.c
#           - ARM mode + LTO (compresses better than Thumb here)

# Ops that an open AP never calls. Removed from wpa_driver_nl80211_ops in the flash build.
DROP_OPS="get_bssid get_ssid scan2 sched_scan stop_sched_scan get_scan_results2 abort_scan
 deauthenticate authenticate associate init2 deinit set_supp_port remain_on_channel
 cancel_remain_on_channel deinit_p2p_cli resume signal_monitor signal_poll add_pmkid
 remove_pmkid flush_pmkid set_rekey_info set_p2p_powersave start_dfs_cac send_tdls_mgmt
 tdls_oper tdls_enable_channel_switch tdls_disable_channel_switch update_ft_ies get_survey
 status switch_channel set_noa get_noa driver_cmd vendor_cmd set_wowlan set_mac_addr
 init_mesh join_mesh leave_mesh br_add_ip_neigh br_delete_ip_neigh br_port_set_attr
 br_set_net_param add_tx_ts del_tx_ts roaming disable_fils do_acs set_band
 get_pref_freq_list set_prob_oper_freq p2p_lo_start p2p_lo_stop set_default_scan_ies
 set_tdls_mode get_bss_transition_status ignore_assoc_disallow set_bssid_blacklist
 configure_data_frame_filters update_connect_params send_external_auth_status set_4addr_mode"
# Objects replaced by open_ap_stubs.c in the flash link.
DROP_OBJS='/(wpa_auth|wpa_auth_ie|wpa_auth_glue|pmksa_cache_auth|ieee802_1x|eapol_auth_sm|eapol_auth_dump|eap_server[a-z_]*|eap_common|eap_user_db|wpa_common|preauth_auth|ms_funcs|tls_[a-z_]*)\.o$|/crypto/'

trim_ops(){ # $1 = driver_nl80211.c ; deletes ".op = fn," entries (incl. 2-line ones)
  awk -v drop="$DROP_OPS" '
    BEGIN { n = split(drop, a, /[ \n]+/); for (i = 1; i <= n; i++) if (a[i] != "") d[a[i]] = 1 }
    /^const struct wpa_driver_ops wpa_driver_nl80211_ops = \{/ { inops = 1 }
    inops && /^};/ { inops = 0 }
    inops && cont { if ($0 ~ /,[ \t]*$/) cont = 0; next }
    inops && match($0, /^\t\.[a-z0-9_]+ =/) {
      op = substr($0, 3, RLENGTH - 4)
      if (op in d) { if ($0 !~ /,[ \t]*$/) cont = 1; removed++; next }
    }
    { print }
    END { print "trim_ops: removed " removed " ops" > "/dev/stderr" }' "$1" > "$1.new" && mv "$1.new" "$1"
}

build_variant(){ # $1=name  $2=extra CFLAGS  $3=extra .config lines  $4=flash(1)/debug(0)
  local v=$1 xc=$2 cfgx=$3 flash=$4
  rm -rf hp-$v; cp -r hostapd-$HOSTAPD_VER hp-$v
  [ "$flash" = 1 ] && trim_ops hp-$v/src/drivers/driver_nl80211.c
  cd hp-$v/hostapd
  cp /recipe/hostapd-2.8.config .config
  if [ "$flash" = 1 ]; then
    sed -i '/^CONFIG_CTRL_IFACE=y/d; /^CONFIG_IEEE80211N=y/d' .config
    printf '%b\n' "$cfgx" >> .config
  fi
  # CFLAGS/LDFLAGS via the ENVIRONMENT (the Makefile appends its own -I../src to them;
  # passing them as make arguments would override that and break every include).
  # _GNU_SOURCE: musl only exposes 'struct ucred' (used by libnl-tiny headers) with it.
  local CF="$ARCHFLAGS $OPT $xc -D_GNU_SOURCE -I$NL/include"
  local LF="$ARCHFLAGS $OPT $xc -static -L$NL -Wl,--gc-sections"
  CFLAGS="$CF" LDFLAGS="$LF" make -j"$(nproc)" hostapd CC="$MCC" >/dev/null
  if [ "$flash" = 1 ]; then
    # Relink: security stack -> open_ap_stubs.c, config_file.c -> mini_config.c,
    # plus lighter libc pieces (libc_overrides.c).
    # These files MUST be built with the exact CFLAGS make used (all -DCONFIG_*): the
    # hostapd structs they touch change layout with those defines. Ask make for them.
    local MKCF; MKCF=$(printf 'print-cflags:\n\t@echo $(CFLAGS)\n' > /tmp/pcf.mk
                      CFLAGS="$CF" make -s -f Makefile -f /tmp/pcf.mk print-cflags)
    case "$MKCF" in *CONFIG_NO_STDOUT_DEBUG*) ;; *) echo "bad CFLAGS from make: $MKCF"; exit 1;; esac
    local x
    for x in open_ap_stubs mini_config libc_overrides; do
      $MCC $MKCF -I. -c /recipe/$x.c -o cc_$x.o
    done
    local objs; objs=$(find .. -name '*.o' ! -name 'cc_*.o' | grep -v -E "$DROP_OBJS|/config_file\.o$" | sort)
    $MCC $LF -o hostapd $objs cc_*.o -lnl-tiny
  fi
  cp hostapd /out/hostapd-$v.unstripped          # for size analysis / gdb, never shipped
  ${CROSS}strip --strip-all -R .comment -R .note hostapd
  cp hostapd /out/hostapd-$v
  $XZ -k -f /out/hostapd-$v
  cd $W
}
build_variant debug "" "" 0
build_variant flash "-flto" "CONFIG_NO_STDOUT_DEBUG=y\nCONFIG_NO_CTRL_IFACE=y" 1

# --- 4. captive-portal DNS (the camera's busybox has no dnsd) ----------------------------
$MCC $ARCHFLAGS $OPT -flto -static -Wl,--gc-sections -o /out/captive-dns /recipe/captive_dns.c
${CROSS}strip --strip-all -R .comment -R .note /out/captive-dns
$XZ -k -f /out/captive-dns

# --- 5. flash bundle: ONE xz stream (the two binaries share musl code -> ~5 KB saved) ---
# On the camera: xzcat ap-bin.tar.xz | tar -x -C /tmp
mkdir -p /tmp/bundle && cp /out/hostapd-flash /tmp/bundle/hostapd && cp /out/captive-dns /tmp/bundle/
tar --format=ustar --owner=0 --group=0 --numeric-owner --mtime=@0 --mode=755 \
    -C /tmp/bundle -cf - hostapd captive-dns | $XZ > /out/ap-bin.tar.xz

# --- 6. report --------------------------------------------------------------------------
cd /out
file hostapd-debug hostapd-flash captive-dns
ls -l hostapd-debug hostapd-debug.xz hostapd-flash hostapd-flash.xz captive-dns captive-dns.xz ap-bin.tar.xz
sha256sum hostapd-debug hostapd-debug.xz hostapd-flash hostapd-flash.xz captive-dns captive-dns.xz ap-bin.tar.xz > SHA256SUMS
cat SHA256SUMS
