#!/system/bin/sh
# Touch report-rate control for RMX5010.
# The Oplus touch HAL exposes node 182 (/proc/touchpanel/report_rate); the
# vendor tool writes it through the same AIDL interface used by ColorOS.
# Select a rate with:
#   settings put global op13_fix_touch_sampling_rate 240
# or tap the module action in KernelSU (action.sh cycles the value).

TOUCH_RATE_KEY=op13_fix_touch_sampling_rate
TOUCH_OWNER_KEY=op13_fix_touch_owner
TOUCH_RATE_NODE=182
TOUCH_HIDL=/odm/bin/touchHidlTest

touch_owner_value() {
  value=$(settings get global "$TOUCH_OWNER_KEY" 2>/dev/null)
  case "$value" in
    ""|null) echo module ;;
    *) echo "$value" ;;
  esac
}

touch_rate_value() {
  # Sense owns the node while its TouchEnhanceManager is active. It mirrors
  # the effective rate into TOUCH_RATE_KEY, so the module must not also write
  # the node on screen transitions.
  [ "$(touch_owner_value)" = "sense" ] && return 1
  value=$(settings get global "$TOUCH_RATE_KEY" 2>/dev/null)
  case "$value" in
    70|120|180|240|360) echo "$value"; return 0 ;;
    *) return 1 ;;
  esac
}

write_touch_rate() {
  rate=$1
  [ -x "$TOUCH_HIDL" ] || return 1
  "$TOUCH_HIDL" -c wo 0 "$TOUCH_RATE_NODE" "$rate" >/dev/null 2>&1
}

apply_touch_rate() {
  rate=$(touch_rate_value) || return 0
  if write_touch_rate "$rate"; then
    log "touch rate applied: $rate Hz"
  else
    log "touch rate failed: $rate Hz"
  fi
}

apply_touch_rate_off() {
  rate=$(touch_rate_value) || return 0
  case "$rate" in
    180|240|360)
      if write_touch_rate 70; then
        log "touch rate screen off: 70 Hz"
      fi
      ;;
  esac
}
