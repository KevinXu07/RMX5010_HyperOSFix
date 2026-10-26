# Sense 作为模块配置前端：评估与学习点

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
KSU 挂载，职责清晰，也不需要把 LSPosed 模块改成一个带 Activity 的应用。
