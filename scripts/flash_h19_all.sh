#!/usr/bin/env bash
# flash_h19_all.sh — 刷写 h19 移植包(分区名显式,§9 规则)
# 前提: 手机在 fastbootd(is-userspace=yes);SLOT 按实际活动槽修改
set -uo pipefail
FB="${FB:-fastboot}"
S="${S:-}"
PKG="${PKG:-/root/h19_build/h19_package}"
SLOT="${SLOT:-_a}"
B="${PKG%/h19_package}/base_os3"   # 精简 my 八件套等底座分区(如已配置)

flash() { echo ">> flash $1 ← $2"; "$FB" $S -S 128M flash "$1" "$2" || { echo "FAIL $1"; exit 1; }; }

for p in odm vendor system system_ext product; do
  flash "$p$SLOT" "$PKG/images/$p.img"
done
# 底座 my 八件套(如目录存在)
if [ -d "$B" ]; then
  for f in my_bigball my_carrier my_engineering my_heytap my_manifest my_product my_region my_stock; do
    [ -f "$B/$f.img" ] && flash "${f}$SLOT" "$B/$f.img"
  done
fi
# vbmeta(avboff 三件套,如目录存在)
if [ -d "${PKG%/h19_package}/vbmeta/avboff" ]; then
  for v in vbmeta vbmeta_system vbmeta_vendor; do
    flash "$v" "${PKG%/h19_package}/vbmeta/avboff/$v.img"
  done
fi
"$FB" $S reboot
echo "刷写完成,重启中。验证: sys.boot_completed / getenforce / getprop ro.product.device"
