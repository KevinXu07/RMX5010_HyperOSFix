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

# ---- display overlays: donor originals carry 140px/169px + 38px padding;
# the port build wants 116/160 + 74/14. Bind size/mtime-matched patched
# overlays before PackageManager scans /product; a cache miss drops the
# overlay and the base framework (116/160) still applies.
overlay_mount() {
  src="$MODDIR/overlay/$1"
  dst="$2"
  [ -f "$src" ] || return 0
  chmod 0644 "$src" 2>/dev/null
  if [ -x /system/bin/chcon ]; then
    /system/bin/chcon u:object_r:system_file:s0 "$src" 2>/dev/null
  fi
  touch -d @0 "$src" 2>/dev/null
  if nsenter -t 1 -m -- mount --bind "$src" "$dst" 2>>"$LOG"; then
    log "overlay: mounted $1"
  else
    log "overlay: mount failed $1"
  fi
}
overlay_mount DevicesAndroidOverlay.apk /product/overlay/DevicesAndroidOverlay.apk
overlay_mount DevicesOverlay.apk /product/overlay/DevicesOverlay.apk
# Auto-brightness curve: lux points re-mapped through the panel's Apollo
# DBV->nits table (stock AB849 P_1) so the screen hits ColorOS lux_table 44
# nits; the image copy maps through a wrong nits table (~50% of stock).
overlay_mount display_id_4630947008615494291.xml \
  /product/etc/displayconfig/display_id_4630947008615494291.xml

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

# ---- HyperOS screen color temperature UI ----
# Xiaomi vendors set these; the ColorOS vendor does not, so Settings shows only
# greyed warm/default/cool buttons (enabled in one mode only).  Enable the
# colour picker in every mode except expert; Sense (ScreenColorBridgeHooks)
# turns the resulting setFeature(mode 23/0/1/2) calls into colour matrices.
if [ -x /data/adb/ksud ]; then
  /data/adb/ksud resetprop ro.colorpick_adjust true 2>/dev/null
  /data/adb/ksud resetprop ro.all_modes.colorpick_adjust true 2>/dev/null
fi
log "screen color picker: $(getprop ro.colorpick_adjust)/$(getprop ro.all_modes.colorpick_adjust)"

# ---- donor mi_ext paths ----
# The donor's mi_ext partition was merged into /product at build time and
# /mi_ext is left as an empty dir, but some readers hard-code /mi_ext with no
# /product fallback:
#   product/ai/taiyi             AIService preinstalled AI plugins/models
#                                (segment -> lockscreen 景深, video_segment, ner)
#   product/etc/cust_features    system_server CustFeatureResolveHelper and
#                                libskuparser_ffi (device/region/SIM features)
# Mirror only the subtrees the donor mi_ext really had; binding all of
# /product would expose files (e.g. operator preinstall lists) that a stock
# mi_ext does not carry.
if [ -e /mi_ext/product ]; then
  log "mi_ext: skipped (already populated)"
elif nsenter -t 1 -m -- sh -c '
    mount -t tmpfs -o mode=0755,context=u:object_r:system_file:s0 tmpfs /mi_ext || exit 1
    for d in ai/taiyi etc/cust_features; do
      [ -d /product/$d ] || continue
      mkdir -p /mi_ext/product/$d && mount --bind /product/$d /mi_ext/product/$d || exit 1
    done
    mkdir -p /mi_ext/product/opcust
    mount -o remount,ro /mi_ext' 2>>"$LOG"; then
  log "mi_ext: $(ls /mi_ext/product/ai/taiyi/config 2>/dev/null | wc -l) taiyi configs, $(ls /mi_ext/product/etc/cust_features 2>/dev/null | wc -l) cust_features entries"
else
  log "mi_ext: mount failed"
fi

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
