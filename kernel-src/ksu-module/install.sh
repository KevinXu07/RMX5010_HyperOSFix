#!/system/bin/sh
# rmx5010_fod_bridge installer
#
# KernelSU 只有在模块里存在 install.sh 时才会把脚本交给模块自己执行，并且
# 只解出 module.prop + install.sh，其余文件不会自动展开。所以这里先自己把
# 整包解到 $MODPATH，再顺带安装 LSPosed / ZygiskNext / Sense。
#
# 环境（由 ksud 提供）：
#   $ZIPFILE  原始模块 zip（例如 /storage/emulated/0/Download/xxx.zip）
#   $MODPATH  目标目录 /data/adb/modules_update/rmx5010_fod_bridge
#   cwd       /dev/tmp

LOG=/data/local/tmp/rmx5010_installer.log
: > "$LOG"

log() {
  echo "$*"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

fail() {
  log "错误：$*"
  log "安装已终止，系统分区没有被改动。修正后可在 KSU 管理器中重新安装。"
  exit 1
}

MODDIR=${MODPATH:-/data/adb/modules_update/rmx5010_fod_bridge}
KSUD=/data/adb/ksud
BB=/data/adb/ksu/bin/busybox
[ -x "$BB" ] || BB=busybox
[ -x "$KSUD" ] || KSUD=/data/adb/ksu/bin/ksud

# ksud 把本脚本的 cwd 设在 /dev/tmp，而下面第 2 步嵌套调用的 ksud module install
# 会把这个临时目录整个删掉。之后任何要用 cwd 的命令都会失败，其中 pm install
# 会直接 SIGABRT（rc=134，getcwd failed），表现就是 Sense 永远装不上。
# 本脚本所有路径都是绝对的，先挪到根目录即可。
cd / 2>/dev/null || cd /data

log "rmx5010_fod_bridge：开始安装"
log "模块包：$ZIPFILE"
log "安装目录：$MODDIR"

# ---------------------------------------------------------------- 1. 解包
[ -f "$ZIPFILE" ] || fail "找不到模块包 $ZIPFILE"
"$BB" unzip -o -q "$ZIPFILE" -d "$MODDIR" >> "$LOG" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "解包失败（rc=$rc），请确认模块包完整、存储空间充足"

# 解包后模块脚本默认是 0644，补回可执行位（KSU action.sh 会直接执行）。
"$BB" chmod 0755 "$MODDIR"/*.sh 2>/dev/null

# KernelSU 在正常安装流程里会把 system/system_ext 提到模块根目录，并给
# system/system_ext 留一个指回根目录的符号链接（system-as-root 设备）。
# 走 install.sh 时这一步不一定发生，自己补上，保证相机库的挂载路径不变。
if [ -d "$MODDIR/system/system_ext" ] && [ ! -L "$MODDIR/system/system_ext" ]; then
  if [ -e "$MODDIR/system_ext" ]; then
    rm -rf "$MODDIR/system_ext"
  fi
  mv "$MODDIR/system/system_ext" "$MODDIR/system_ext" || fail "移动 system_ext 失败"
  ln -s ../system_ext "$MODDIR/system/system_ext" || fail "创建 system_ext 链接失败"
  log "system_ext 已提升到模块根目录"
fi

# 载荷完整性检查：相机 APK 是模块的核心，缺了就不要让它开机。
CAM_APK="$MODDIR/camera/priv-app/MiuiCamera/OplusCamera.apk"
[ -f "$CAM_APK" ] || fail "模块载荷不完整：缺少 $CAM_APK"
cam_size=$("$BB" stat -c %s "$CAM_APK" 2>/dev/null)
[ "$cam_size" = "193164793" ] || fail "相机 APK 大小异常（$cam_size），模块包可能已损坏"
[ -f "$MODDIR/rmx5010_fod_bridge.ko" ] || fail "模块载荷不完整：缺少 rmx5010_fod_bridge.ko"
[ -f "$MODDIR/service.sh" ] || fail "模块载荷不完整：缺少 service.sh"
log "模块载荷校验通过（相机 APK $cam_size B）"

# ------------------------------------------------- 2. LSPosed / ZygiskNext
INSTALLED_ANY=0

module_present() {
  [ -d "/data/adb/modules/$1" ] || [ -d "/data/adb/modules_update/$1" ]
}

install_module() {
  id=$1
  zip=$2
  label=$3
  if module_present "$id"; then
    log "$label 已安装，跳过"
    return 0
  fi
  if [ ! -f "$zip" ]; then
    log "$label 安装包缺失（$zip），跳过"
    return 1
  fi
  log "正在安装 $label …"
  "$KSUD" module install "$zip" >> "$LOG" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && module_present "$id"; then
    log "$label 安装成功，重启后生效"
    INSTALLED_ANY=1
    return 0
  fi
  log "$label 安装失败（rc=$rc），已把安装包放到 /sdcard/Download/rmx5010_installer/ 供手动安装"
  mkdir -p /sdcard/Download/rmx5010_installer
  cp -f "$zip" /sdcard/Download/rmx5010_installer/ 2>/dev/null
  return 1
}

install_module zygisksu "$MODDIR/installer/zygisknext-1.5.2.zip" "ZygiskNext"
install_module zygisk_lsposed "$MODDIR/installer/LSPosed-v2.2.1-7912-release.zip" "LSPosed"

# ------------------------------------------------------------- 3. Sense APK
# 没装就装；已装但 versionCode 低于内置版本就用 pm install -r 原地升级（同一
# release 签名，LSPosed 启用状态和作用域不变）。签名不同（例如 debug 签名版）
# 系统不允许覆盖，跳过并提示，APK 留给用户手动处理。
SENSE_APK="$MODDIR/installer/Sense-1.48.apk"
SENSE_VERSION_CODE=41

sense_installed_code() {
  dumpsys package com.zephiel.sense 2>/dev/null |
    "$BB" grep -m1 -o 'versionCode=[0-9]*' | "$BB" cut -d= -f2
}

sense_copy_for_user() {
  mkdir -p /sdcard/Download/rmx5010_installer
  cp -f "$SENSE_APK" /sdcard/Download/rmx5010_installer/ 2>/dev/null
}

# $1 = 日志里用的动作（安装 / 升级）
sense_pm_install() {
  cp -f "$SENSE_APK" /data/local/tmp/rmx5010_sense.apk
  chmod 0644 /data/local/tmp/rmx5010_sense.apk
  log "正在$1 Sense …"
  out=$(pm install -r /data/local/tmp/rmx5010_sense.apk 2>&1)
  rc=$?
  echo "$out" >> "$LOG"
  rm -f /data/local/tmp/rmx5010_sense.apk
  if [ "$rc" -eq 0 ] && [ "$(sense_installed_code)" = "$SENSE_VERSION_CODE" ]; then
    log "Sense $1成功"
    INSTALLED_ANY=1
  elif echo "$out" | "$BB" grep -q 'UPDATE_INCOMPATIBLE'; then
    log "已装的 Sense 与本包签名不同，系统不允许覆盖，跳过$1。需要新版请先卸载 com.zephiel.sense 再重新安装本模块（之后要在 LSPosed 里重新启用、重勾作用域），APK 已复制到 /sdcard/Download/rmx5010_installer/"
    sense_copy_for_user
  else
    log "Sense $1失败（rc=$rc），APK 已复制到 /sdcard/Download/rmx5010_installer/"
    sense_copy_for_user
  fi
}

if [ ! -f "$SENSE_APK" ]; then
  log "Sense 安装包缺失（$SENSE_APK），跳过"
elif [ -z "$(pm path com.zephiel.sense 2>/dev/null)" ]; then
  sense_pm_install 安装
else
  code=$(sense_installed_code)
  case "$code" in
    ''|*[!0-9]*)
      log "Sense 已安装，但读不到版本号（$code），跳过" ;;
    *)
      if [ "$code" -lt "$SENSE_VERSION_CODE" ]; then
        log "Sense 已安装（versionCode $code），低于本包的 $SENSE_VERSION_CODE"
        sense_pm_install 升级
      else
        log "Sense 已安装（versionCode $code），不低于本包的 $SENSE_VERSION_CODE，跳过"
      fi ;;
  esac
fi

# ------------------------------------------------------------- 4. 钱包套件
# ColorOS 钱包 5 件套随模块打包（来源与 SHA-256 见 THIRD_PARTY_NOTICES.md）。
# 它们是普通用户应用，装在 /data/app；已存在的跳过，签名不一致装不上时把
# APK 放到 /sdcard/Download/rmx5010_installer/ 供手动处理。
WALLET_DIR="$MODDIR/installer/wallet"

wallet_install() {
  pkg=$1
  apk=$2
  if [ ! -f "$apk" ]; then
    log "钱包组件缺失：$(basename "$apk")，跳过"
    return 0
  fi
  if [ -n "$(pm path "$pkg" 2>/dev/null)" ]; then
    log "钱包组件已存在：$pkg"
    return 0
  fi
  cp -f "$apk" /data/local/tmp/rmx5010_wallet.apk
  chmod 0644 /data/local/tmp/rmx5010_wallet.apk
  pm install -r /data/local/tmp/rmx5010_wallet.apk >> "$LOG" 2>&1
  rc=$?
  rm -f /data/local/tmp/rmx5010_wallet.apk
  if [ "$rc" -eq 0 ] && [ -n "$(pm path "$pkg" 2>/dev/null)" ]; then
    log "钱包组件安装成功：$pkg"
    INSTALLED_ANY=1
  else
    log "钱包组件安装失败：$pkg（rc=$rc），APK 已复制到 /sdcard/Download/rmx5010_installer/"
    mkdir -p /sdcard/Download/rmx5010_installer
    cp -f "$apk" /sdcard/Download/rmx5010_installer/ 2>/dev/null
  fi
}

wallet_install com.finshell.wallet "$WALLET_DIR/FinShellWallet.apk"
wallet_install com.heytap.tas "$WALLET_DIR/TasWallet.apk"
wallet_install com.heytap.htms "$WALLET_DIR/HeytapHTMS.apk"
wallet_install com.unionpay.tsmservice "$WALLET_DIR/UPTsmService.apk"
wallet_install com.oplus.eid "$WALLET_DIR/EidService.apk"

# 注册 Sense 的 LSPosed 作用域（含钱包进程），避免装完还要手动进管理器勾选。
# lspd 的数据库要等 LSPosed 第一次跑起来才存在；装 LSPosed 与本次安装同批时
# 这里会跳过，由 service.sh 在首次开机后补注册（之后再重启一次生效）。
LSPD_DB=/data/adb/lspd/config/modules_config.db
SCOPE_DEX="$MODDIR/installer/lspdscope.dex"
SENSE_SCOPES="android system com.android.systemui com.android.bluetooth com.android.settings com.miui.securitymanager com.miui.securitycenter org.ifaa.aidl.manager com.xiaomi.finddevice com.android.nfc com.android.se com.finshell.wallet com.heytap.tas com.unionpay.tsmservice com.oplus.eid com.miui.tsmclient com.oplus.camera"

sense_register_scopes() {
  if [ ! -f "$LSPD_DB" ] || [ ! -f "$SCOPE_DEX" ]; then
    log "LSPosed 数据库尚未创建，Sense 作用域由 service.sh 在首次开机后补注册"
    return 0
  fi
  apk_path=$(pm path com.zephiel.sense 2>/dev/null | sed -n 's/^package://p' | head -1)
  if [ -z "$apk_path" ]; then
    log "Sense 未安装，跳过作用域注册"
    return 0
  fi
  cp -f "$SCOPE_DEX" /data/local/tmp/rmx5010_lspdscope.dex
  log "正在注册 Sense 的 LSPosed 作用域 …"
  ( cd /data/local/tmp && CLASSPATH=rmx5010_lspdscope.dex \
      /system/bin/app_process /system/bin LspdModule "$LSPD_DB" \
      com.zephiel.sense "$apk_path" $SENSE_SCOPES ) >> "$LOG" 2>&1
  rc=$?
  log "Sense 作用域注册 rc=$rc"
  rm -f /data/local/tmp/rmx5010_lspdscope.dex
  # 标记交给 service.sh 的开机兜底看：注册过就不再重复写数据库。
  # v2: 增加 com.oplus.camera（相册缩略图 hook），旧标记会让开机兜底跳过。
  [ "$rc" -eq 0 ] && touch "$MODDIR/.sense_scopes_registered_v2" 2>/dev/null
}

sense_register_scopes

# ------------------------------------------------------------------ 5. 收尾
if [ "$INSTALLED_ANY" = "1" ]; then
  log "全部完成：重启一次以启用 ZygiskNext / LSPosed / Sense。"
else
  log "全部完成：依赖组件均已存在，无需额外安装，重启后模块生效。"
fi
log "详细日志：$LOG"
exit 0
