# patches/signal-fix — 信号（掉线/反复横跳）双保险修复

两个**互相独立**的病因，同一症状（双卡信号反复掉、数据链断）：

| # | 病因 | 载体 | 参照 |
|---|---|---|---|
| 1 | 小米 OEM XTS/RIL 查询在 Oplus modem 上**阻塞电话主线程** → STK/SIM ANR 循环 | `system/priv-app/TeleService/TeleService.apk`（dex 补丁） | OS3 时代**本机实机验证过**的同一手法 |
| 2 | CNE 进程在重复注销网络回调时抛 `NetworkCallback was not registered` **崩溃** → 数据链断 | `vendor/app/CneApp/CneApp.apk`（dex 补丁） | 一加 13 的 `CneDataCallCrashGuard`（LSPosed hook）→ 此处改成改包 |

## 1. TeleService（XtsApp）

三处改动（[smali/XtsApp.smali](smali/XtsApp.smali) 是打过补丁的完整文件，可直接与你的版本对照）：

```smali
# (a) onInitVerInfo()V           -> 整体 no-op（只留 return-void）
#     （跳过 ModemUtils.getDeviceName/getHwInfo/getBuildRegion/getManufacturerId... 一串采集）
# (b) onInitVerInfo(OemHookAgent) -> 整体 no-op
#     （跳过 getModemHalChipId/getModemChipId/getBuildProfile/getManufacturerId/
#       getOemProductFlag/isHalDecoupled 这些真正的 OEM RIL 查询）
# (c) onHookDone()               -> 在 notifyRegistrants() 之后立即 return-void
#     （跳过 getVerInfoWithoutName / isXtsSupported / startXtsService —— 与 OS3 实机验证版同一切断点）
```

保留 `unregisterHookReadyEvent` + `notifyRegistrants()`：其它依赖 hook-ready 的组件照常收到通知。

**签名处理**：`TeleService` 与平台共享 UID/权限，不能重签（历史结论 + OS3 实测），所以采用
**保留原 APK Signing Block**（4088 字节，v2/v3 的 signer 证书仍在，摘要因 dex 变更而失效）——
这正是 OS3 时代在本机型实机上跑通的做法（`TeleService-patched-signedblock-v3.apk`）。

## 2. CNE（CneApp）

`com.qualcomm.qti.cne` → `DataCallAgent$Tracker.destroyNetworkRequest()` 原本只有 4 条指令：

```smali
iget-object v0, p0, ...->mConnectivityManager
iget-object v1, p0, ...->mNetworkCallback
invoke-virtual {v0, v1}, Landroid/net/ConnectivityManager;->unregisterNetworkCallback(...)V
return-void
```

改成 try/catch（[smali/DataCallAgent_Tracker.smali](smali/DataCallAgent_Tracker.smali)）：
`IllegalArgumentException` 被吞掉并打 `CneDataCallGuard` 警告日志，其余异常照常上抛。

**注意 shared UID**：CneApp 与 `vendor.qti.iwlan` 共用 `sharedUserId=com.qualcomm.qti.qtidataservices`，
单独重签会触发 `INSTALL_FAILED_SHARED_USER_INCOMPATIBLE` → 同样采用**保留原签名块**。

## 构建与刷写

```bash
scripts/build_teleservice_patch.sh    # 需要 java + smali/baksmali 2.5.2 fat jar（dex 039）
scripts/build_cne_guard_patch.sh      # 需要 目标机型的 vendor/app/CneApp/CneApp.apk
```

两者都做了：dex 重编译往返校验（除补丁文件外仅剩"静态字段默认值省略"的序列化差异）、
zip 完整性、非 dex 条目逐字节一致、签名块结构（两处 size 字段 + magic 一致）。

刷写：`fastboot -S 128M flash system_a images\system.img`（进 fastbootd）。
**签名摘要已变，需 `fastboot -w` 清 userdata 后刷入**。

## 验证清单（实机）

```bash
# TeleService（信号）
adb shell 'dumpsys telephony.registry | grep -E "mServiceState|mSignalStrength"'   # 双卡 IN_SERVICE 稳定
adb shell 'logcat -d | grep -iE "XtsApp|onInitVerInfo|ANR in com.android.phone"' | tail -30
# CNE（数据链）
adb shell 'logcat -d | grep -iE "CneDataCallGuard|NetworkCallback was not registered"' | tail -20
adb shell 'dumpsys package com.qualcomm.qti.cne | head -5'                          # 包仍在（未被签名校验丢弃）
```

## 回滚

`_before_signal_mtp_dpi/images/{system,vendor}.img`（本轮改动前），单分区回刷即可。

## 已知未做

音频"哔"声（抖音切歌/暂停）：本版镜像里小米的 `appname` 参数代码位于
`system/lib64/libaudiopolicymanagerdefault.so`（`strings` 5 处命中；haotian 时代那份是
`libaudiopolicymanagerimpl.so`，本版无此库）。下一步：定位引用 `appname=` 的函数，把入口改成
`ret`（ARM64 `c0 03 5f d6`），做法与 haotian 时代一致。

---

## 2026-10-25 补充（haotian 主线）：0.19 TeleService 重打

donor 切到 haotian OS4.0.0.19 后，对 **0.19 自带 TeleService** 重新执行同一补丁
（`build_teleservice_patch.sh` 流程，非移植旧 APK）：三处标记点
（两个 `onInitVerInfo` 变体声明、`onHookDone` 的 `:try_end_1d/.catchall :catchall_48`
标记）与 nezha 时代完全一致，补丁无适配成本。原 signing block 拼回手法不变
（4 个 block id 校验一致）。随 h19 system.img 刷入，实机开机正常。
CNE 防崩（病因 2）本轮**未**重打——需按同一方法对 0.19 的 CneApp 重做，待观察信号回归再定。
