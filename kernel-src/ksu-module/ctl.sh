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
  echo "haptic_scale=$(get_global "$HAPTIC_SCALE_KEY" 1.0)"
  echo "ifaa_model=$(get_global "$IFAA_MODEL_KEY" ONEPLUS-R23821)"
  echo "ifaa_domain=$(ifaa_domain)"
  echo "wallet_installed=$(has_package "$WALLET_PACKAGE" && echo 1 || echo 0)"
  echo "wallet_appop=$(wallet_appop)"
  echo "lsp_main=$(has_package "$LSP_MAIN" && echo 1 || echo 0)"
  echo "lsp_wallet=$(has_package "$LSP_WALLET" && echo 1 || echo 0)"
  echo "audio_mounted=$(audio_mounted && echo 1 || echo 0)"
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
  log "haptic scale: $value"
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

reapply() {
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
  reapply) reapply ;;
  *)
    echo "usage: ctl.sh {status|status-file|grant-wallet|test-wallet|set-haptic <0.3-1.2>|set-ifaa-model <model>|apply-touch-module|reapply}" >&2
    exit 2
    ;;
esac
