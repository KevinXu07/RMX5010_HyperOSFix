#!/system/bin/sh
# KernelSU module action: cycle the touch report rate and apply it now.
MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/rmx5010_fod_bridge
LOG="$MODDIR/action.log"

log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
}

. "$MODDIR/touch_rate.sh"

current=$(touch_rate_value) || current=unset
case "$current" in
  70) next=120 ;;
  120) next=180 ;;
  180) next=240 ;;
  240) next=360 ;;
  360) next=70 ;;
  *) next=120 ;;
esac

settings put global "$TOUCH_RATE_KEY" "$next"
log "action: touch rate $current -> $next"
apply_touch_rate
echo "touch sampling rate: $next Hz"
