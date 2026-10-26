#!/system/bin/sh
# KernelSU module action: cycle the touch report rate and apply it now.
MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/rmx5010_fod_bridge
LOG="$MODDIR/action.log"

log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
}

. "$MODDIR/touch_rate.sh"

if [ ! -e "$TOUCH_RATE_NODE_FILE" ]; then
  echo "touch report_rate is not exposed by this touch driver; dynamic rate unsupported"
  log "action: report_rate node absent"
  exit 0
fi

# A manual KernelSU action takes ownership back from Sense; Sense will take
# it again the next time its TouchEnhanceManager applies a rate.
settings put global "$TOUCH_OWNER_KEY" module

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
