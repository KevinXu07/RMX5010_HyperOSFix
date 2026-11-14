# Xiaomi millet kernel driver for HyperOS Greeze.
#
# Greeze freezes background apps through the cgroup freezer and relies on the
# millet driver (netlink 31, ro.millet.netlink) to thaw them when a network
# packet, signal or binder call arrives.  The RMX5010 (Oplus) kernel has no
# millet, so millet_monitor crash-loops and Greeze runs with
# MilletEnable=false: frozen apps with their own long connection (WeChat, QQ)
# only wake on the next alarm.
#
# The donor (Xiaomi 15 Pro haotian, same SM8750 / android15-6.6 GKI) ships the
# driver as vendor_boot modules.  They are GKI KMI modules: every imported
# symbol CRC matches this kernel, the struct module layout is the GKI one
# (cleanup_module at 0x5b8), and the binder/signal hooks are android_vh_*
# (multi-registration, shared with oplus_sys_hans).
#
# Details: docs/Millet内核驱动_移植与验证.md
#
# Off switch: touch /data/adb/rmx5010_millet_off (post-fs-data cannot read
# Settings), then reboot.

MILLET_DIR="$MODDIR/millet"
MILLET_OFF=/data/adb/rmx5010_millet_off
# Dependency order (donor modules.dep): core first, binder_gki before
# millet_binder, millet_binder also needs millet_pkg.
MILLET_MODULES="millet_core binder_gki millet_pkg millet_hs millet_binder millet_sig millet_oem_cgroup"

millet_log() {
  echo "$(date '+%m-%d %H:%M:%S') millet: $*" >> "$LOG"
}

# post-fs-data: before system_server (Greeze) and millet_monitor start.
load_millet() {
  if [ -e "$MILLET_OFF" ]; then
    millet_log "disabled by $MILLET_OFF"
    return 0
  fi
  if [ -d /sys/module/millet_core ]; then
    millet_log "already loaded"
    return 0
  fi
  case "$(uname -r)" in
    6.6.*-android15-*) ;;
    *) millet_log "skip: kernel $(uname -r) is not android15-6.6"; return 1 ;;
  esac
  for m in $MILLET_MODULES; do
    ko="$MILLET_DIR/$m.ko"
    if [ ! -f "$ko" ]; then
      millet_log "missing $m.ko"
      return 1
    fi
    chmod 0644 "$ko" 2>/dev/null
    if ! insmod "$ko" 2>>"$LOG"; then
      millet_log "insmod $m failed, stop"
      return 1
    fi
  done
  millet_log "loaded ($(ls /proc/millet 2>/dev/null | tr '\n' ' '))"
}

millet_greeze_state() {
  case "$(dumpsys greezer 2>/dev/null | grep -m1 'MilletEnable=')" in
    *true*) echo 1 ;;
    *false*) echo 0 ;;
    *) echo unknown ;;
  esac
}

# service stage, after boot_completed.  millet_monitor registers its three
# monitor tokens with Greeze only after the kernel answers a HANDSHK message,
# and that exchange is driven by Greeze's own loop (nLoopOnce).  When the
# monitor came up before Greeze was ready the registration never happens;
# "cmd greezer loop" runs the same nLoopOnce and completes it
# (verified 2026-11-13: monitor=0 -> 7, MilletEnable=false -> true).
ensure_millet() {
  [ -d /sys/module/millet_core ] || return 0
  i=0
  while [ $i -lt 30 ]; do
    [ "$(millet_greeze_state)" = 1 ] && { millet_log "greeze MilletEnable=true after ${i}s"; return 0; }
    sleep 2
    i=$((i+1))
  done
  for attempt in 1 2 3; do
    cmd greezer loop >/dev/null 2>&1
    sleep 3
    if [ "$(millet_greeze_state)" = 1 ]; then
      millet_log "greeze MilletEnable=true after loop (attempt $attempt)"
      return 0
    fi
    setprop ctl.restart millet_monitor
    sleep 5
  done
  millet_log "greeze MilletEnable still $(millet_greeze_state)"
  return 1
}
