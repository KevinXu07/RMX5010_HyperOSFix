#!/system/bin/sh
# Unified status/control plane for the RMX5010 KSU module.
# Sense reads `status` and invokes the explicit actions below through su;
# nothing here runs periodically.

MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/rmx5010_fod_bridge
LOG="$MODDIR/ctl.log"

TOUCH_RATE_KEY=op13_fix_touch_sampling_rate
TOUCH_OWNER_KEY=op13_fix_touch_owner
HAPTIC_SCALE_KEY=op13_fix_haptic_scale
IFAA_MODEL_KEY=op13_fix_ifaa_model
WALLET_PACKAGE=com.finshell.wallet
WALLET_SWIPE_CLASS=com.nearme.wallet.nfc.ui.NfcConsumeActivity
WALLET_OPEN_ACTION=finshell.wallet.intent.action.OPEN
WALLET_SESSION_EXTRA=local.mio.coloroswalletcompat.extra.LOCKSCREEN_SESSION
LSP_MAIN=local.mio.gt7profodfix
LSP_WALLET=local.mio.coloroswalletcompat
IFAA_PACKAGE=org.ifaa.aidl.manager
GMS_UNFREEZE_KEY=op13_fix_gms_unfreeze
GREEZE_ALLOW_KEY=op13_fix_greeze_allow
GREEZE_ALLOW_DEFAULT="com.tencent.mm com.tencent.mobileqq"
GREEZE_CLOUD_KEY=immobulus_mode_switch_restrict

log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
}

get_global() {
  value=$(settings get global "$1" 2>/dev/null)
  case "$value" in
    ""|null) echo "$2" ;;
    *) echo "$value" ;;
  esac
}

has_package() {
  pm list packages "$1" 2>/dev/null | grep -qx "package:$1"
}

module_version() {
  awk -F= '$1 == "version" { print $2; exit }' "$MODDIR/module.prop" 2>/dev/null
}

ifaa_domain() {
  ps -AZ 2>/dev/null \
    | awk -v pkg="$IFAA_PACKAGE" '$NF == pkg { split($1,a,":"); print a[3]; exit }'
}

gms_limit_state() {
  case "$(dumpsys greezer 2>/dev/null | grep -m1 'mGmsLimitEnabled')" in
    *true*) echo 1 ;;
    *false*) echo 0 ;;
    *) echo unknown ;;
  esac
}

audio_mounted() {
  [ -f "$MODDIR/audio.log" ] && grep -q 'mounted ' "$MODDIR/audio.log" 2>/dev/null
}

wallet_appop() {
  appop=$(cmd appops get "$WALLET_PACKAGE" 10020 2>/dev/null)
  case "$appop" in
    *allow*) echo allow ;;
    *ignore*) echo ignore ;;
    *) echo unknown ;;
  esac
}

print_status() {
  echo "module=$(basename "$MODDIR")"
  echo "version=$(module_version)"
  echo "boot_time=$(date '+%Y-%m-%d %H:%M:%S')"
  echo "touch_rate=$(get_global "$TOUCH_RATE_KEY" 120)"
  echo "touch_owner=$(get_global "$TOUCH_OWNER_KEY" module)"
  echo "touch_supported=$(grep -q 'report_rate_white_list_support' /data/vendor/touchconfig/sys_touch_function_feature_config.xml 2>/dev/null && grep -q 'game_mode_divided_report_rate_support' /data/vendor/touchconfig/sys_touch_function_feature_config.xml 2>/dev/null && echo 1 || echo 0)"
  echo "touch_driver=$(grep 'report rate' /proc/touchpanel/debug_info/main_register 2>/dev/null | sed 's/.*: //')"
  echo "haptic_scale=$(get_global "$HAPTIC_SCALE_KEY" 1.0)"
  echo "ifaa_model=$(get_global "$IFAA_MODEL_KEY" ONEPLUS-R23821)"
  echo "ifaa_domain=$(ifaa_domain)"
  echo "wallet_installed=$(has_package "$WALLET_PACKAGE" && echo 1 || echo 0)"
  echo "wallet_appop=$(wallet_appop)"
  echo "lsp_main=$(has_package "$LSP_MAIN" && echo 1 || echo 0)"
  echo "lsp_wallet=$(has_package "$LSP_WALLET" && echo 1 || echo 0)"
  echo "audio_mounted=$(audio_mounted && echo 1 || echo 0)"
  echo "gms_unfreeze=$(get_global "$GMS_UNFREEZE_KEY" 1)"
  echo "gms_limit=$(gms_limit_state)"
  echo "greeze_allow=$(greeze_allow_list)"
  echo "millet_loaded=$([ -d /sys/module/millet_core ] && echo 1 || echo 0)"
  echo "millet_greeze=$(case "$(dumpsys greezer 2>/dev/null | grep -m1 'MilletEnable=')" in *true*) echo 1 ;; *false*) echo 0 ;; *) echo unknown ;; esac)"
}

status_file() {
  print_status > "$MODDIR/status.conf"
  log "status written"
}

grant_wallet() {
  if ! has_package "$WALLET_PACKAGE"; then
    log "wallet not installed"
    return 1
  fi
  cmd appops set "$WALLET_PACKAGE" 10020 allow >/dev/null 2>&1
  log "wallet show-when-locked: $(wallet_appop)"
}

test_wallet() {
  if ! has_package "$WALLET_PACKAGE"; then
    log "wallet not installed"
    return 1
  fi
  am start -a "$WALLET_OPEN_ACTION" \
    -n "$WALLET_PACKAGE/$WALLET_SWIPE_CLASS" \
    --ez "$WALLET_SESSION_EXTRA" true \
    -f 0x34080000 >/dev/null 2>&1
  log "wallet swipe page launched"
}

set_haptic() {
  value=$1
  case "$value" in
    0.[3-9]|1.[0-2]|1) settings put global "$HAPTIC_SCALE_KEY" "$value" ;;
    *) log "invalid haptic scale: $value"; return 1 ;;
  esac
  fifo=$(awk -v s="$value" 'BEGIN { if (s < 0.3) s = 0.3; if (s > 1.0) s = 1.0; printf "%d", 600 + 7600 * (s - 0.3) / 0.7 }')
  direct=$(awk -v f="$fifo" 'BEGIN { d = 1280 * f / 8200; if (d < 200) d = 200; printf "%d", d }')
  if [ -e /sys/class/qcom-haptics/fifo_vmax ]; then
    echo "$fifo" > /sys/class/qcom-haptics/fifo_vmax 2>/dev/null
    echo "$direct" > /sys/class/qcom-haptics/vmax 2>/dev/null
    echo "$direct" > /sys/class/qcom-haptics/cl_vmax 2>/dev/null
  fi
  log "haptic scale: $value fifo_vmax=$fifo direct_vmax=$direct"
}

set_ifaa_model() {
  [ -n "$1" ] || return 1
  settings put global "$IFAA_MODEL_KEY" "$1"
  log "ifaa model: $1"
}

apply_touch_module() {
  settings put global "$TOUCH_OWNER_KEY" module
  . "$MODDIR/touch_rate.sh"
  apply_touch_rate
  log "touch owner: module"
}

# HyperOS CN Greeze quick-freezes com.google.android.gms ~60 s after
# screen-off (mGmsLimitEnabled), which stalls FCM until the next screen-on.
# "dumpsys greezer IM GMS disable|enable" is AurogonImmobulusMode's own debug
# switch for that flag; it resets to true whenever system_server restarts.
apply_gms_push() {
  want=$(get_global "$GMS_UNFREEZE_KEY" 1)
  if [ "$want" = 0 ]; then
    dumpsys greezer IM GMS enable >/dev/null 2>&1
  else
    dumpsys greezer IM GMS disable >/dev/null 2>&1
  fi
  log "gms push: unfreeze=$want gms_limit=$(gms_limit_state)"
}

set_gms_push() {
  case "$1" in
    0|1) settings put global "$GMS_UNFREEZE_KEY" "$1" ;;
    *) log "invalid gms unfreeze value: $1"; return 1 ;;
  esac
  apply_gms_push
}

# Without Xiaomi's millet kernel driver (now loaded by millet_fix.sh; if it is
# switched off or fails, millet_monitor crash-loops) Greeze cannot thaw a
# frozen app when a packet arrives (reportNet never fires).  Its launch-mode
# freeze on every screen-on
# ("LM FZ") then leaves apps with their own long connection frozen until the
# next alarm: WeChat notifications arrive in bursts minutes late.  Put them on
# AurogonImmobulusMode.mAllowList via its debug command.  Greeze rebuilds that
# list whenever the cloud string Settings.Secure immobulus_mode_switch_restrict
# changes, so remember which string we applied on and redo it after a change.
greeze_allow_list() {
  v=$(get_global "$GREEZE_ALLOW_KEY" "$GREEZE_ALLOW_DEFAULT")
  [ "$v" = none ] && v=
  echo "$v"
}

greeze_cloud_sig() {
  settings get secure "$GREEZE_CLOUD_KEY" 2>/dev/null | md5sum | cut -d' ' -f1
}

apply_greeze_allow() {
  for p in $(greeze_allow_list); do
    dumpsys greezer LM add "$p" >/dev/null 2>&1
  done
  greeze_cloud_sig > "$MODDIR/.greeze_cloud_sig"
  log "greeze LM allow: $(greeze_allow_list)"
}

check_greeze_allow() {
  [ "$(cat "$MODDIR/.greeze_cloud_sig" 2>/dev/null)" = "$(greeze_cloud_sig)" ] && return 0
  apply_greeze_allow
}

reapply() {
  apply_gms_push
  apply_greeze_allow
  grant_wallet
  status_file
  log "reapply complete"
}

case "$1" in
  status) print_status ;;
  status-file) status_file ;;
  grant-wallet) grant_wallet ;;
  test-wallet) test_wallet ;;
  set-haptic) set_haptic "$2" ;;
  set-ifaa-model) set_ifaa_model "$2" ;;
  apply-touch-module) apply_touch_module ;;
  apply-gms-push) apply_gms_push ;;
  set-gms-push) set_gms_push "$2" ;;
  apply-greeze-allow) apply_greeze_allow ;;
  check-greeze-allow) check_greeze_allow ;;
  reapply) reapply ;;
  *)
    echo "usage: ctl.sh {status|status-file|grant-wallet|test-wallet|set-haptic <0.3-1.2>|set-ifaa-model <model>|apply-touch-module|apply-gms-push|set-gms-push <0|1>|apply-greeze-allow|check-greeze-allow|reapply}" >&2
    exit 2
    ;;
esac
