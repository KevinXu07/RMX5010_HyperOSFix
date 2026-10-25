#!/system/bin/sh
# system.prop 的兜底：显式 resetprop（KernelSU 域下已验证可写）
MODDIR=${0%/*}
RP=/data/adb/ksu/bin/resetprop
[ -x "$RP" ] || RP=resetprop
while IFS='=' read -r k v; do
  case "$k" in ''|\#*) continue;; esac
  "$RP" -n "$k" "$v"
done < "$MODDIR/system.prop"
