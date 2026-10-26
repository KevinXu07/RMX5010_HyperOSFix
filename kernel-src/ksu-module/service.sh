#!/system/bin/sh
MODDIR=${0%/*}
LOG="$MODDIR/boot.log"
: > "$LOG"

log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
}

# ---- FOD touch bridge ----
i=0
while [ $i -lt 60 ]; do
  [ -d /sys/module/oplus_bsp_tp_notify ] && break
  sleep 1
  i=$((i+1))
done
chmod 0644 "$MODDIR/rmx5010_fod_bridge.ko" 2>>"$LOG"
insmod "$MODDIR/rmx5010_fod_bridge.ko" >> "$LOG" 2>&1
log "insmod rc=$?"

# ---- double tap to wake ----
# HyperOS never programs the Oplus touch LPWG gesture mode, so the panel never
# reports the double-tap gesture and KEY_F4 never reaches the framework.
# Program it through the Oplus touch HAL:
#   node 1  = double_tap_enable : 1
#   node 21 = gesture_type mask : 2 -> kernel gesture_type bit0 (double tap)
# touchDaemon keeps the state in-process and re-sends it on every screen-off,
# so it only has to be (re)applied after boot or a touchDaemon restart.
TOUCH_SVC=vendor.oplus.hardware.touch.IOplusTouch/default

set_gesture() {
  service call "$TOUCH_SVC" 4 i32 0 i32 1 s16 1 >/dev/null 2>&1
  service call "$TOUCH_SVC" 4 i32 0 i32 21 s16 2 >/dev/null 2>&1
}

i=0
applied=0
while [ $i -lt 180 ]; do
  out=$(service call "$TOUCH_SVC" 4 i32 0 i32 21 s16 2 2>/dev/null)
  case "$out" in
    *00000001*)
      service call "$TOUCH_SVC" 4 i32 0 i32 1 s16 1 >/dev/null 2>&1
      log "gesture applied after $i s: $out"
      applied=1
      break
      ;;
  esac
  sleep 1
  i=$((i+1))
done
[ "$applied" = 1 ] || log "gesture apply timed out"

# ---- generic acc_udevid (Xiaomi account uDevId) ----
# acc_udevid = "ud:" + b64url(sha1(account + fid))[:16], fid from the
# FindDevice software credential. Runs after user unlock (CE DB appears)
# and only inserts when the account extras are missing the value.
(
  while true; do
    if [ -f /data/system_ce/0/accounts_ce.db ] && [ -f /mnt/vendor/persist/fdsd/dc ]; then
      out=$(cd "$MODDIR" && CLASSPATH=udevgen.dex app_process /system/bin UdevGeneric \
        /data/system_ce/0/accounts_ce.db /mnt/vendor/persist/fdsd/dc 2>&1)
      case "$out" in
        *inserted*|*updated*|*error*|*no-xiaomi*|*no-fid*|*no-json*)
          log "udevid: $out" ;;
      esac
    fi
    sleep 60
  done
) >> "$LOG" 2>&1 &

# Watch for touchDaemon restarts (gesture state is per-process).
(
  last_pid=
  while true; do
    pid=$(pidof touchDaemon 2>/dev/null)
    if [ -n "$pid" ] && [ "$pid" != "$last_pid" ]; then
      set_gesture
      log "gesture applied for touchDaemon pid=$pid"
      last_pid="$pid"
    fi
    sleep 30
  done
) >> "$LOG" 2>&1 &
