# Sense 作为模块配置前端：评估与学习点

状态（2026-10-27）：**已落地为“一个 KSU 模块 + Sense 作为唯一 LSPosed 模块”**。
Sense 内已经包含 RMX5010 主 hooks 和 ColorOS 钱包 hooks，同时提供“移植修复”
配置页。下面的评估保留为设计依据和冲突分析。

结论：**能接，而且比在 LSPosed 模块里另做一套 UI 更合适**。但要把 Sense 定位成
“控制面”，LSPosed/KSU 仍是“执行面”，不要互相复制逻辑。

## 1. Sense 现状

```text
package    com.zephiel.sense（中文名“感知”）
UI         Jetpack Compose + Material 3，targetSdk 37
进程       SenseService（可选前台服务）、BootReceiver
Root       RootUtils：持久 `su` shell + 结束标记 + 超时/重试
存储       Device Protected Storage 的 SharedPreferences
现有管理器：
  AodBrightnessManager
  CpuGovernorManager
  DisplayColorModeManager
  FingerprintFixManager
  LiftToWakeManager
  ShortcutKeyManager
  TouchEnhanceManager
  VibrationManager
```

Sense 已经具备“配置 + Root 执行 + 日志 + 开机恢复”的完整骨架，缺的只是把
RMX5010 移植模块的几个设置接进来。

## 2. 建议的接入方式

### 2.1 单一契约：Settings.Global

模块已经读取这些键：

```text
op13_fix_touch_sampling_rate   120 / 180 / 240 / 360（也可 70）
op13_fix_haptic_scale          0.3 .. 1.2（当前设备 0.8）
op13_fix_ifaa_model            IFAA 型号，默认 ONEPLUS-R23821
```

Sense 通过 `RootUtils.exec("settings put global <key> <value>")` 写入即可；
模块的 system_server hook / KSU watcher 会在下一次读取时生效。不需要暴露
ContentProvider、AIDL 或广播。

### 2.2 建议新增的 Sense 页面/卡片

“移植修复”分组，四行：

- 触控采样率：复用现有 `TouchEnhanceManager` 的滑条，但**不要自己再写节点
  182**；改成写 `op13_fix_touch_sampling_rate`，由模块的 `touch_rate.sh`
  统一负责亮灭屏切换。否则 Sense 和模块会互相覆盖。
- 触感强度：滑条 0.3–1.2，写 `op13_fix_haptic_scale`；模块的
  `VibrationScaler` 已经实测生效（0.7 → 振幅 0.70）。
- IFAA 型号：文本框 + “恢复默认”，写 `op13_fix_ifaa_model`；修改后
  `am force-stop org.ifaa.aidl.manager` 让下次绑定重新读取。
- 状态：显示 KSU 模块 `boot.log` / `audio.log` 的摘要，以及 IFAA/LHDC
  是否加载。不建议直接解析 LSPosed 日志，耦合太强。

### 2.3 状态文件（可选但推荐）

让 `service.sh` 每次启动写一个轻量 JSON：

```text
/data/adb/modules/rmx5010_fod_bridge/status.json
```

字段：`ifaa_domain`、`touch_rate`、`audio_mount`、`boot_time`、`patch_version`。
Sense 用 root 读取并显示，比抓 logcat 稳定。

## 3. 三处必须先解决的冲突

### 3.1 触控采样率：双写

`TouchEnhanceManager` 目前直接执行：

```text
/odm/bin/touchHidlTest -c wo 0 182 <rate>
```

模块的 `touch_rate.sh` 也会写同一个节点。同时开会导致亮灭屏时互相覆盖。
**接入时应只保留一个写入者**：推荐 Sense 写设置，模块写节点。

### 3.2 抬起亮屏：Sense 不服从系统开关

`LiftToWakeManager` 是独立的加速度计 + `SCREEN_BRIGHT_WAKE_LOCK` 路径，不读
`pick_up_gesture_wakeup_mode`。系统开关关闭时它仍能唤醒，违反“严格服从
系统开关”。

二选一：

1. 在 `LiftToWakeManager.setEnabled/start` 前读取系统设置，关闭时不注册；
2. 或在 Sense 中移除/停用独立抬起亮屏，只保留系统 type 22 路径。

### 3.3 触感：Sense 的 sys.haptic.* props 与模块的 scale

`VibrationManager` 会写大量：

```text
sys.haptic.motor / sys.haptic.infinitelevel / sys.haptic.down.*
sys.haptic.tap.* / sys.haptic.keyboard / ...
```

这些是小米/OPPO 私有属性，RMX 的 qcom HV haptics 是否全部消费需要逐项验证。
模块的 `VibrationScaler` 强度系数已经实测有效。建议：

- 把 Sense 的 VibrationManager 作为“实验性原生调参”入口，默认关闭；
- 默认使用模块的 `op13_fix_haptic_scale`；
- 不要同时启用两套，避免用户无法判断是哪套在生效。

## 4. 从 Sense 可以学习的设计

1. **Manager 生命周期统一**：`setEnabled`、`setDebugLogging`、`onDestroy`、
   RootFailureListener；每个功能独立失败，不拖垮整个服务。
2. **持久 Root shell**：`RootUtils` 用 `echo __END__<id>:$?` 标记命令结束，
   带超时和异常重连；比每次 `su -c` 更稳定。
3. **Device Protected Storage**：开机阶段（用户未解锁）也能读取配置。
4. **单个前台服务 + SharedPreferences 监听**：配置变化即时下发到各
   Manager，不需要每个页面各自保活。
5. **权限/状态自检**：Root、通知策略、无障碍、KSU 安装状态都有明确提示。
6. **Compose 偏好组件与日志查看器**：适合做“移植修复”这种轻量控制面板。
7. **失败可见**：Root 失败、节点写入失败、重试次数都在 UI/日志里，
   便于用户反馈。

## 5. 建议的落地顺序

1. 先把“触控采样率/触感强度/IFAA 型号”三行接进 Sense，复用现有页面；
2. 解决 Sense 与模块的双写（触控）和冲突（抬起亮屏）；
3. 增加 `status.json` 和“导出日志”按钮；
4. 再考虑把 LHDC/IFAA 的详细诊断做成只读卡片。

这样 Sense 是用户能看见、能调的入口；模块继续负责 hook、SELinux、HAL 和
KSU 挂载，职责清晰。最终形态进一步把主 hooks 与钱包 hooks 并入 Sense，
使 Sense 同时成为唯一的 LSPosed 模块。

## 6. 实际落地结果（2026-10-27）

### 6.1 模块结构

```text
KSU 模块   rmx5010_fod_bridge（显示名 RMX5010 HyperOS Fix，1.1.0）
           FOD 桥、双击亮屏、触控采样率、音频 bind mount、
           IFAA SELinux、钱包锁屏 AppOp、ctl.sh/status
LSPosed    com.zephiel.sense（唯一模块）
           17 个 RMX5010 Java hooks + 4 个钱包 Kotlin 文件
           + assets/oplus-fwk.jar + jniLibs/arm64-v8a 三个 LHDC 库
UI         Sense“移植修复”页
```

Sense 的 `SenseXposedEntry` 同时调用
`local.mio.gt7profodfix.HookEntry` 和
`local.mio.coloroswalletcompat.HookEntry`；钱包 hook 的
`startupParam.modulePath` 指向 Sense APK，因此 `assets/oplus-fwk.jar`
仍能被正确加载。`BluetoothHooks` 现在优先从 `com.zephiel.sense` 的
`nativeLibraryDir` 加载 `libop13_lhdc_patch.so`，同时保留旧包名回退；
`packaging.jniLibs.useLegacyPackaging=true` 保证 .so 被解压到 nativeLibraryDir。

### 6.2 Sense“移植修复”页

- 模块状态：KSU 版本、LSP 激活、触控/触感、钱包/刷卡权限、音频补丁、IFAA。
- 触感强度：0.3–1.2，写 `op13_fix_haptic_scale`。
- IFAA 型号：写 `op13_fix_ifaa_model`，并重启 IFAA 进程。
- 测试锁屏刷卡页：重新授权 AppOp 10020 后启动 `NfcConsumeActivity`。
- 重新应用模块配置：调用 KSU `ctl.sh reapply` 并刷新状态。

### 6.3 冲突处理

- **触控**：Sense 的 `TouchEnhanceManager` 在应用采样率时写
  `op13_fix_touch_owner=sense` 并镜像 `op13_fix_touch_sampling_rate`；
  KSU `touch_rate.sh` 看到 owner=sense 就不再写节点。手动 KernelSU action
  会把 owner 改回 module。
- **抬起亮屏**：`LiftToWakeManager` 读取
  `pick_up_gesture_wakeup_mode`，用 ContentObserver 跟随系统开关；
  系统关闭时立即注销传感器。
- **触感**：Sense 原有的 `sys.haptic.*` 保留为实验性入口，默认关闭，
  文案提示与模块 `op13_fix_haptic_scale` 二选一。

### 6.4 实机验证

- SukiSU 授权 Sense（UID 10318）后，`SenseService` 根命令可用；
  `ctl.sh` 返回 `touch_owner=sense`、`wallet_appop=allow`、`audio_mounted=1`。
- 重启后 LSPosed 日志显示所有进程都使用 `com.zephiel.sense`：
  `system_server hooks installed`、`SystemUI hooks installed`、
  `wallet gesture -> FinShell swipe hook installed`、
  `ColorOSWalletCompat: ...`。
- 解锁与锁屏双击电源键都进入 `NfcConsumeActivity`；锁屏页面覆盖 Keyguard，
  没有 `PermissionDenied`/`QAWalletSClient`。
- 旧模块 `local.mio.gt7profodfix` 和 `local.mio.coloroswalletcompat`
  已卸载，避免重复 hook。

### 6.5 回滚

迁移前的 APK 和 LSPosed 配置备份在：

```text
E:\code\modify\haotian_work\sense_migration\
/data/local/tmp/modules_config.db.before_sense
```

回滚时卸载 `com.zephiel.sense`，重装两个旧 LSPosed APK，恢复
`modules_config.db.before_sense` 后重启。注意 Sense 卸载会清掉 Sense 设置。
