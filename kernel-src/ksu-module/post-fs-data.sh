#!/system/bin/sh
# Audio policy appname-parameter patch.
#
# audioserver loads libaudiopolicymanagerimpl.so / libmiaudiopolicymanager.so
# from its own mount namespace (init's). Bind-mount the patched copies before
# audioserver starts; the patched copies are identical except for the eight
# appname setParameters calls (blr x8 -> nop).
MODDIR=${0%/*}
LOG="$MODDIR/audio.log"
: > "$LOG"

log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
}

log "post-fs-data uptime: $(cat /proc/uptime 2>/dev/null)"

# ---- touch report-rate config ----
. "$MODDIR/touch_config.sh"
ensure_touch_config
log "touch config: $?"

# ---- SurfaceFlinger touch boost ----
# ro.surface_flinger.set_touch_timer_ms=0 disables the compositor touch timer,
# so an app that requests 30Hz for a video keeps the whole UI at 30Hz even
# while the comments list is being scrolled.  Restore a 2s touch boost; the
# compositor raises the refresh rate for interaction and drops back to the
# video/content rate after the timer expires.
if [ -x /data/adb/ksud ]; then
  /data/adb/ksud resetprop ro.surface_flinger.set_touch_timer_ms 2000 2>/dev/null
fi
log "sf touch timer: $(getprop ro.surface_flinger.set_touch_timer_ms)"

# ---- OplusCamera systemless port ----
# Hide MiuiCamera, mount OplusCamera/provider stub into priv-app, merge camera
# permission XMLs, add the missing seapp_contexts mapping and P010 lib.
. "$MODDIR/camera_fix.sh"
ensure_camera_port
log "camera port: $?"

SRC="$MODDIR/audio"
TARGET=/system_ext/lib64
for f in libaudiopolicymanagerimpl.so libmiaudiopolicymanager.so; do
  if [ ! -f "$SRC/$f" ]; then
    log "missing $SRC/$f"
    continue
  fi
  if [ -x /system/bin/chcon ]; then
    /system/bin/chcon u:object_r:system_lib_file:s0 "$SRC/$f" 2>>"$LOG"
  fi
  if nsenter -t 1 -m -- mount --bind "$SRC/$f" "$TARGET/$f" 2>>"$LOG"; then
    log "mounted $f"
  else
    log "mount failed $f"
  fi
done

for f in libaudiopolicymanagerimpl.so libmiaudiopolicymanager.so; do
  hash=$(nsenter -t 1 -m -- sha256sum "$TARGET/$f" 2>/dev/null | awk '{print $1}')
  log "target $f=$hash"
done

# ---- QESDK / QAPE seccomp policy + qseelogd ----
# The vendor allow-lists are missing lseek, so QESDK/QAPE/syshealthmon crash
# every few seconds and qseelogd spins on the TZ log stream.  Mount the fixed
# policies before the HAL services start, and turn the log daemon off.
. "$MODDIR/qesdk_fix.sh"
ensure_qesdk_policy
log "qesdk policy: $?"
apply_qseelogd_fix

# ---- WeChat: hide the ODM fake CameraX library declaration ----
# The fake jar contains old Kotlin classes; WeChat's optional uses-library
# resolves them and aborts.  The permission XML is the only registration
# point, so hide it before PackageManager scans /odm.
. "$MODDIR/wechat_fix.sh"
ensure_wechat_camera_fix
log "wechat camera fix: $?"
