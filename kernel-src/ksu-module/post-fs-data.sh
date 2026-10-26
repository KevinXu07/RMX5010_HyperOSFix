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

# ---- touch report-rate config ----
. "$MODDIR/touch_config.sh"
ensure_touch_config
log "touch config: $?"

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
