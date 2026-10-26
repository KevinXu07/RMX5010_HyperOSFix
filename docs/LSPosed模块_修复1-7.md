# LSPosed 模块：移植修复 1~7（GT7 Pro / RMX5010）

本模块是 `os4/external/OP13HyperOSFix`（一加 13 综合修复）的**精简移植版**，
只保留作用在 system_server / SystemUI 的 1~7 项，去掉了需要 App UI、Gradle、
NDK、以及一加特有硬件的部分（LHDC、核心破解、通知、IFAA、旁路充电、场景调度等）。

## 1. 覆盖面

| # | 修复 | 实现位置 | GT7 Pro 适配 |
|---|---|---|---|
| 1 | F4 单击/双击唤醒（AOD） | `SystemServerHooks` → `PhoneWindowManager#interceptKeyBeforeQueueing`，280 ms 双击窗、500 ms 冷却，单击注入 key 354 | 真机 `touchpanel`（event5）能力表含 `KEY_F4`（已用 `getevent -pl` 实测） |
| 2 | F4 距离门控 | 同上，`startedGoingToSleep` 注册 wakeup type 8、`finishedWakingUp` 注销；近则拒绝唤醒 | 真机 type 8 = `tcs3720 Proximity Sensor Wakeup` ✅ |
| 3 | 抬起亮屏 | `SystemUiHooks#hookPickupSensor`：`KeyguardSensorInjector` 改注册 wakeup type 22，raw `0↔1` 翻转 | 真机 type 22 = `pick_up_motion` Wakeup ✅（与一加 13 相同） |
| 4 | FOD 移动 / 口袋 | `SystemUiHooks#hookFodSensors`：移动用 `33171026`（raw 2↔1）；口袋用 type 8（近=NonUI） | 真机 `33171026 amd_oplus` Wakeup ✅、type 8 ✅ |
| 5 | 指纹按压事件 | 内核桥 `rmx5010_fod_bridge.ko` 输出 `KEY_F5`；system_server 校验 scan 63 + 设备名 `op13_fod_bridge` 后向 SystemUI 发 `FINGERPRINT_DOWN/UP` 广播；SystemUI 侧条件式补偿 | 桥设备名保持 `op13_fod_bridge` 以复用上游 hook；真机 `oplus_fp_input` 只有 KEY_W/E/R，不能用，桥是唯一可靠来源 |
| 6 | 指纹速启 450 ms | `SystemUiHooks#hookFodManager`：dismiss 后若 `mShowRunnable` 在队列则改为统一 450 ms；短触残留按整屏触摸状态决定是否 `dismiss(1)` | 与机型无关，依赖 haotian OS4 的 `MiuiGxzwManager` 类名/字段 |
| 7 | 步数传感器 | `SystemServerHooks#hookStepCounter`：`StepCounterManagerService` 改 `getDefaultSensor(18,false)`，并强制 `support_steps_provider=true` | 真机 type 18 为 non-wakeup 计步器 ✅ |

范围（LSPosed 作用域）：`android`（system_server）、`com.android.systemui`。

## 2. 与一加 13 版的差异

- 删除了 `ManageAllNotificationsHooks`、`IfaaHooks`、`MiCharge*`、`VolumeIslandHooks`、
  `GameOptimizationHooks`、`CorePatchHooks`、`DiagnosticMarkers`、根引导广播
  （KO 由 KernelSU 模块加载，不再依赖 App 里的 su 流程）。
- 删除了整屏 AOD 面板桥（`OplusAodPanelBridge`）与设置页/UI 相关逻辑。
- 包名改为 `local.mio.gt7profodfix`，但**桥设备名仍是 `op13_fod_bridge`**，
  这是 system_server 侧 `isFodBridgeEvent()` 的匹配依据，改名要同步改两处。

## 2.1 haotian OS4（0.19）目标类静态核实（2026-10-25）

拉取真机 `MiuiSystemUI.apk`（`/system_ext/priv-app/MiuiSystemUI/MiuiSystemUI.apk`）与
`services.jar` 后逐类确认：

| 类 | 所在 | 结论 |
|---|---|---|
| `com.miui.keyguard.biometrics.fod.MiuiGxzwSensor` | MiuiSystemUI classes3.dex | ✅ |
| `...fod.MiuiGxzwManager` | classes.dex/2/3 | ✅ |
| `...fod.MiuiGxzwIconView` / `MiuiGxzwQuickOpenView` / `MiuiGestureMonitor` | classes3 / classes | ✅ |
| `com.android.keyguard.injector.KeyguardSensorInjector` | 三个 dex 均有 | ✅（注意包名是 `com.android.keyguard.injector`，不是 `com.miui.keyguard`） |
| `com.android.systemui.shade.PulsingGestureListener` | classes2.dex | ✅ |
| `com.android.server.policy.PhoneWindowManager` | services.jar | ✅ |
| `com.miui.server.stepcounter.StepCounterManagerService` | **`/system_ext/framework/miui-services.jar`** classes2.dex | ✅（启动类路径，system_server 可见） |
| `miui.util.FeatureParser` | framework.jar（启动类路径） | ✅ |

真机输入设备能力（`getevent -pl`）：

- `touchpanel`（event5）支持 `KEY_F4`，还有两个厂商码 `02f8/02f9`；
- `oplus_fp_input`（event3）只有 `KEY_W/E/R`，锁屏时不上报——证实 FOD 事件只能靠内核桥；
- 我们的桥 `op13_fod_bridge`（event8/9，随启动时序变化）只有 `KEY_F5`。

## 3. 构建（离线，无需 Gradle/网络）

```bash
cd lsposed-src
bash build_apk.sh
# 产物：lsposed-src/RMX5010_HyperOSFix_lsposed.apk
```

依赖：Android Studio 自带 JBR（javac/keytool）、SDK build-tools 36.0.0
（aapt2 / d8 / zipalign / apksigner）、`platforms/android-37.0/android.jar`。
`xposed-api-stub/` 只是编译期占位，不打进 APK；运行时由 LSPosed 提供。

## 4. 安装

1. 安装 `RMX5010_HyperOSFix_lsposed.apk`（无桌面图标）。
2. LSPosed 管理器 → 模块 → 启用「RMX5010 HyperOS Fix」。
3. 作用域勾选：**Android 系统**、**系统界面**。
4. 重启（或重启 system_server / SystemUI）。
5. 配合内核桥：`kernel-src/ksu-module` 已安装时，指纹区按下/抬起会生成
   `op13_fod_bridge` 设备的 `KEY_F5`。

## 5. 验证

```bash
# hook 是否装上（XposedBridge.log 输出到 LSPosed 日志，也可 logcat 过滤）
adb logcat -s Xposed | grep -i "RMX5010\|GT7Pro"
# 期望看到：
#   SystemServerHooks: system_server hooks installed
#   SystemUiHooks: SystemUI hooks installed in com.android.systemui

# 内核桥是否在
adb shell su -c 'grep op13_fod_bridge /proc/modules; getevent -pl | grep -A2 op13_fod_bridge'

# 指纹按压事件（手指按住屏幕指纹区，亮屏/息屏都可试）
adb shell su -c 'getevent -l /dev/input/eventX'   # eventX 以 getevent -pl 结果为准
# 期望：KEY_F5 DOWN / UP
```

## 6. 已知风险 / 待实机确认

- F4 是否在**息屏低功耗 AOD** 阶段由触摸固件上报：已确认 HyperOS 默认不会开启 LPWG，
  `gesture_type=0` 时驱动息屏直接深睡、根本不发 F4。必须先用触摸 HAL 写
  `node1=1 / node21=2` 使能双击手势（KSU `service.sh` 已固化），见
  `docs/双击亮屏_LPWG根因与修复.md`。使能后息屏日志出现
  `low power gesture mode enabled`，双击即产生 `KEY_F4`（scan=62）。
  注意：RMX5010 的 HBP 固件**一次双击只发一个 F4**（dmesg `Gesture ID=1`），
  因此钩子已改为单 F4 直接唤醒，且使用 `PowerManager.wakeUp()`（`wakeUpFromWakeKey()`
  对该事件无效）。
- haotian OS4 的 `KeyguardSensorInjector` / `MiuiGxzwSensor` 若类名或字段与
  haotian 0.19 有出入，hook 会走 `Reflect` 失败分支（只记日志、不崩）。
- 距离门控 / 口袋判断依赖 type 8 的首个值；未收到值时 fail-open（不阻塞唤醒）。
- 本模块不含 HBM 逻辑：OS4 驱动自己处理，额外写 HBM 会导致低功耗 AOD 指纹后黑屏（一加 13 已验证）。
