#!/system/bin/sh
MODDIR=${0%/*}
LOG="$MODDIR/boot.log"
: > "$LOG"

log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
}

# ---- touch report-rate config (retry if post-fs-data was too early) ----
. "$MODDIR/touch_config.sh"
ensure_touch_config
touch_config_rc=$?
log "touch config: $touch_config_rc"
if [ "$touch_config_rc" = 0 ]; then
  setprop ctl.restart touchDaemon
  sleep 2
  log "touchDaemon restarted after config patch"
fi

# ---- QESDK / QAPE: fix seccomp allow-list, stop TZ log spam ----
. "$MODDIR/qesdk_fix.sh"
ensure_qesdk_policy
qesdk_rc=$?
log "qesdk policy: $qesdk_rc"
apply_qseelogd_fix
if [ "$qesdk_rc" = 0 ]; then
  # post-fs-data normally mounts the policies before these services start;
  # restart here so a module update without reboot also picks them up.
  for s in $QESDK_SERVICES; do stop "$s" 2>/dev/null; done
  sleep 1
  for s in $QESDK_SERVICES; do start "$s" 2>/dev/null; done
  log "qesdk services restarted"
fi

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

# ---- configurable touch report rate ----
# Node 182 (/proc/touchpanel/report_rate) is written through the Oplus touch
# HAL. The setting is optional; when unset the Realme firmware default is kept.
. "$MODDIR/touch_rate.sh"
(
  last_on=
  while true; do
    brightness=$(cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null)
    if [ -n "$brightness" ] && [ "$brightness" -gt 0 ]; then
      on=1
    else
      on=0
    fi
    if [ "$on" != "$last_on" ]; then
      if [ "$on" = 1 ]; then
        apply_touch_rate
      else
        apply_touch_rate_off
      fi
      last_on=$on
    fi
    sleep 5
  done
) >> "$LOG" 2>&1 &

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

# ---- IFAA / Alipay fingerprint payment: SELinux live patch ----
# IFAA runs in a versioned platform_app domain (platform_app_36 on this base)
# and the Oplus IFingerprintPay HAL only accepts hal_fingerprintpay_client.
# The live patch is lost on reboot; the marker lives in /dev (tmpfs) so a
# reboot always reapplies it. Re-check whenever the IFAA process (re)starts.
IFAA_DOMAIN_MARK=/dev/ifaa_policy_domains

ifaa_domain() {
  domain=$(ps -AZ 2>/dev/null \
    | awk '$NF == "org.ifaa.aidl.manager" { split($1,a,":"); print a[3]; exit }')
  [ -n "$domain" ] && { echo "$domain"; return; }

  target=$(dumpsys package org.ifaa.aidl.manager 2>/dev/null \
    | grep -o 'targetSdk=[0-9][0-9]*' | head -n 1 | cut -d= -f2)
  sdk=$(getprop ro.build.version.sdk 2>/dev/null)
  [ -n "$sdk" ] || sdk=37
  if [ -n "$target" ] && [ "$target" -ge "$sdk" ]; then
    echo platform_app
  else
    echo "platform_app_$((sdk - 1))"
  fi
}

apply_ifaa_policy() {
  domain=$(ifaa_domain)
  case "$domain" in
    platform_app|platform_app_[0-9]*|system_app|system_app_[0-9]*) ;;
    *) log "ifaa policy skipped: domain=$domain"; return ;;
  esac
  grep -qx "$domain" "$IFAA_DOMAIN_MARK" 2>/dev/null && return
  rule="typeattribute $domain hal_fingerprintpay_client"
  if [ -x /data/adb/ksu/bin/ksud ] \
     && /data/adb/ksu/bin/ksud sepolicy check "$rule" >/dev/null 2>&1 \
     && /data/adb/ksu/bin/ksud sepolicy patch "$rule" >/dev/null 2>&1; then
    echo "$domain" >> "$IFAA_DOMAIN_MARK"
    log "ifaa policy patched: $rule"
  else
    log "ifaa policy failed: $rule"
  fi
}
apply_ifaa_policy
(
  last_domain=
  while true; do
    if pidof org.ifaa.aidl.manager >/dev/null 2>&1; then
      domain=$(ifaa_domain)
      if [ -n "$domain" ] && [ "$domain" != "$last_domain" ]; then
        apply_ifaa_policy
        last_domain="$domain"
      fi
    else
      last_domain=
    fi
    sleep 30
  done
) >> "$LOG" 2>&1 &

# ---- ColorOS wallet: allow the swipe page over the lock screen ----
# HyperOS gates FLAG_SHOW_WHEN_LOCKED behind AppOps 10020 (MIUIOP(10020)).
# FinShell is installed as a user app here, so the unprivileged default is
# "ignore": Keyguard pauses NfcConsumeActivity, then FinShell's onStop path
# finishes it. Grant only the wallet package; this is the same visibility a
# preinstalled system wallet gets.
(
  i=0
  while [ $i -lt 120 ]; do
    [ "$(getprop sys.boot_completed)" = 1 ] && break
    sleep 1
    i=$((i+1))
  done
  if pm list packages 2>/dev/null | grep -qx 'package:com.finshell.wallet'; then
    out=$(cmd appops set com.finshell.wallet 10020 allow 2>&1)
    log "wallet show-when-locked: ${out:-ok}"
  else
    log "wallet show-when-locked: package absent"
  fi
  sh "$MODDIR/ctl.sh" status-file >> "$LOG" 2>&1
) >> "$LOG" 2>&1 &

# OplusCamera default role/runtime permissions after PackageManager has scanned
# the systemless priv-app mount.
. "$MODDIR/camera_fix.sh"
camera_post_boot >> "$LOG" 2>&1 &

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

# ---- per-game frame rate override ----
# game_fps.sh waits for boot_completed, applies the rule once, then watches
# while the game runs.  This also works if the Sense GameManager hook is not
# loaded early enough for GameManagerService.updateConfigsForUser().
if [ -f "$MODDIR/game_fps.sh" ]; then
  # KernelSU extracts module files with 0644; invoke through sh instead of
  # relying on the executable bit.
  sh "$MODDIR/game_fps.sh" >> "$LOG" 2>&1 &
  log "game fps watcher started"
fi
