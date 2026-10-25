#!/system/bin/sh
MODDIR=${0%/*}
LOG="$MODDIR/boot.log"
: > "$LOG"
i=0
while [ $i -lt 60 ]; do
  [ -d /sys/module/oplus_bsp_tp_notify ] && break
  sleep 1
  i=$((i+1))
done
chmod 0644 "$MODDIR/rmx5010_fod_bridge.ko" 2>>"$LOG"
insmod "$MODDIR/rmx5010_fod_bridge.ko" >> "$LOG" 2>&1
echo "insmod rc=$?" >> "$LOG"
