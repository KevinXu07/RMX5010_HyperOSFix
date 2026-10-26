#!/system/bin/sh
# Enable Oplus touch report-rate control on RMX5010.
#
# The RMX boot image's touchDaemon defaults
# report_rate_white_list_support / game_mode_divided_report_rate_support to
# false, so it rejects report_rate writes even though touchHidlTest returns 0.
# The patched XML enables both flags; once it wins version selection, node 182
# maps to real frame-rate changes (120/180/240/360).
TOUCH_CFG=/data/vendor/touchconfig/sys_touch_function_feature_config.xml
TOUCH_PATCH=${MODDIR:-/data/adb/modules/rmx5010_fod_bridge}/touch/sys_touch_function_feature_config.xml
TOUCH_ORIG_SHA=9b352e16ec4b0305cc794c511e26c00466914b4da264401a3d7754011fa2edc5

ensure_touch_config() {
  [ -f "$TOUCH_CFG" ] || return 1
  if grep -q 'report_rate_white_list_support' "$TOUCH_CFG" 2>/dev/null; then
    return 2
  fi
  current=$(sha256sum "$TOUCH_CFG" 2>/dev/null | awk '{print $1}')
  [ "$current" = "$TOUCH_ORIG_SHA" ] || return 3
  [ -f "$TOUCH_PATCH" ] || return 4
  cp -f "$TOUCH_CFG" "$TOUCH_CFG.bak_touchrate" || return 5
  cp -f "$TOUCH_PATCH" "$TOUCH_CFG" || return 6
  chown root:root "$TOUCH_CFG" 2>/dev/null
  chmod 0600 "$TOUCH_CFG" 2>/dev/null
  [ -x /system/bin/restorecon ] && /system/bin/restorecon "$TOUCH_CFG" 2>/dev/null
  return 0
}
