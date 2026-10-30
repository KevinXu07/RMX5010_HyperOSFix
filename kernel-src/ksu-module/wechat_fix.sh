#!/system/bin/sh
# WeChat crash fix: hide the ODM fake CameraX extension declaration.
#
# The ODM image ships /odm/framework/androidx.camera.extensions.impl.fake.jar
# with old Kotlin/AndroidX classes.  WeChat's optional uses-library loads it and
# then dies with NoSuchMethodError (kotlin.coroutines.Continuation.getContext).
# The shared library is registered only by the permission XML below, so
# bind-mounting an empty declaration removes it from PackageManager without
# touching the read-only /odm partition or the jar itself.
WECHAT_CAMERA_XML="$MODDIR/wechat/fake_camera_extensions.xml"
WECHAT_CAMERA_TARGET=/odm/etc/permissions/fake_camera_extensions.xml

ensure_wechat_camera_fix() {
  [ -f "$WECHAT_CAMERA_XML" ] || return 1

  # Already hidden in this boot (or the vendor already removed it).
  if ! grep -q 'androidx.camera.extensions.impl' "$WECHAT_CAMERA_TARGET" 2>/dev/null; then
    return 0
  fi

  chmod 0644 "$WECHAT_CAMERA_XML"
  if [ -x /system/bin/chcon ]; then
    /system/bin/chcon u:object_r:vendor_configs_file:s0 "$WECHAT_CAMERA_XML" 2>/dev/null
  fi
  if /system/bin/nsenter -t 1 -m -- mount --bind "$WECHAT_CAMERA_XML" \
      "$WECHAT_CAMERA_TARGET" 2>/dev/null; then
    log "wechat: fake camera library declaration hidden"
    return 0
  fi
  if mount --bind "$WECHAT_CAMERA_XML" "$WECHAT_CAMERA_TARGET" 2>/dev/null; then
    log "wechat: fake camera library declaration hidden (local ns)"
    return 0
  fi
  log "wechat: fake camera declaration mount failed"
  return 1
}
