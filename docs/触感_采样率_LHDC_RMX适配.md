# 触感 / 触控采样率 / LHDC：RMX5010 适配记录

状态（2026-10-26）：

| 项目 | 状态 |
|---|---|
| 触感私有效果映射 + 支持列表扩展 | ✅ 实机加载（map=1/info=1） |
| RMX 触感强度系数 | ✅ 实测 0.7 生效（scale=0.70，Step 振幅 0.70） |
| 触控采样率节点 182 + 亮灭屏切换 | ❌ 实机确认驱动未暴露 `report_rate`；HAL 调用返回 0 但速率不变 |
| LHDC V5 软件编码器桥接 | ✅ 实机安装成功（status=7），⏳ 未接 LHDC 耳机试听 |

## 1. 触感

### 1.1 RMX 的振动链路

```text
android.hardware.vibrator.IVibrator/default
  capabilities = ON_CALLBACK, PERFORM_CALLBACK, AMPLITUDE_CONTROL, EXTERNAL_CONTROL
  supportedEffects = [CLICK, DOUBLE_CLICK, TICK, THUD, POP, HEAVY_CLICK, 6..12]
驱动：qcom-hv-haptics（PMIH010x HV haptics），LRA nominal impedance 9 Ω
资源：/odm/etc/vibrator/vibrator_effect.json（809 机型，effect_*.bin，24 kHz）
```

RMX 上没有 OP13 的 `IOplusVibrator` / 300+ 私有效果，也没有 194 份小米 RTP。
因此 **不能直接移植 OP13 的 RTP 播放器**；RMX 能用的是 AOSP 0..12 预制效果、
Step 波形和振幅控制。

### 1.2 HyperOS 实际发的是什么

实测设置页“点按时振动”和 Xiaomi 输入法按键：

```text
reason: TAG=pattern_vibration;keyword=MIUI_SDK
played: Step=75ms(amplitude=1.00)            # 键盘
played: Step=45/67/79ms(...)                  # 设置预览
usage: TOUCH，scale: NONE (1.00)
```

它们走的是 **Step 波形**，不是私有效果 ID，RMX HAL 能正常播放。真正会
被 HAL 拒绝的是 HyperOS 的私有效果（162/163 返回手势、72、73、106、206、
209、210 等），因为 `VibratorInfo.supportedEffects` 只有 0..12。

### 1.3 已实现的兼容层

`HapticHooks`（system_server）：

- Hook `android.os.vibrator.PrebakedSegment.getEffectId()`，把 HyperOS 私有
  ID 映射到 RMX 支持的 0..12（映射表见源码；返回手势 162→7、163→2，
  FOD 73/159/191→4，锁屏 209→3，指纹解锁 210→4，错误 165/174→12 等）。
- Hook `VibratorManagerService.getVibratorInfo*`，把上述 ID 加入
  `mSupportedEffects`，让 SystemUI/Launcher 的
  `areEffectsSupported()` 不会提前跳过。
- 只声明模块实际会翻译的 ID，不声称支持无关的游戏/铃声效果。

### 1.4 RMX 强度系数

- Hook `VibrationScaler.getScaleFactor(int usage, boolean)`。
  **注意 OS4 的实际签名是 `(IZ)F`，不是 `(VibrationAttributes)F`**；早期
  按对象类型判断导致 hook 完全不生效，已修正。
- 对非 ALARM / NOTIFICATION / RINGTONE / COMMUNICATION_REQUEST / MEDIA
  的反馈类振动，乘以 `op13_fix_haptic_scale`（默认 1.0，范围 0.3..1.2）。
- 实测：

```bash
adb shell su -c 'settings put global op13_fix_haptic_scale 0.7'
# 敲键盘后 dumpsys vibrator_manager：
scale: NONE (0.70)
played: Step=75ms(amplitude=0.70)
# LSPosed：
RMX5010HyperOSFix: haptic feedback scale=0.7
```

设备最终采用 **0.8** 作为起点；这是针对 RMX LRA 的保守校准，用户可以随时
改回 1.0 或调到 0.6。

2026-10-27 手感调整：LRA 的振幅响应不是线性的，等距滑条在中低段变化偏弱。
`HapticHooks.feedbackScale()` 现在在用户值上应用 1.35 次幂曲线：

```text
factor = clamp(pow(slider, 1.35), 0.2, 1.2)
slider 0.8 -> factor 0.74
slider 1.0 -> factor 1.00
slider 1.2 -> factor 1.20
```

滑条仍显示 0.3–1.2 的用户值，底层只把这个曲线后的系数交给
`VibrationScaler`；1.0 不变，两端仍在 0.2–1.2 的测试范围内。

2026-10-27 实测（“测试触感”80ms 单次）：

```text
scale=0.3 -> VibrationScaler 0.20, played amplitude 0.20
scale=1.2 -> VibrationScaler 1.20, played amplitude 1.00 (硬件上限)
scale=0.8 -> 0.74
```

同时把系数缓存从 3000ms 改为 500ms，避免滑条改完后立刻测试仍用旧值；
测试提示音从 45ms 延长到 80ms，便于分辨强度。曲线是否更线性需要实际手感
确认；如果要回退，把指数改回 1.0 即可。

### 1.5 仍未做的部分

- MIUI_SDK 的 75 ms 键盘 Step 本身还没有按 RMX 马达缩短。要改波形需要在
  `VibratorManagerService` 的 usage 边界重建 `VibrationEffect`，属于下一步
  手感调参；当前先用强度系数解决“过冲/过强”。
- OP13 的全局触感滑条、MiRemix、视频触感、通知长按/清理/指纹成功失败等
  RTP 功能依赖 `IOplusVibrator` 和小米 RTP 资源，在 RMX 上不可直接复用。
- 指纹成功/失败触感需要至少一枚已录指纹才能实机验证。

## 2. 触控采样率

### 2.1 节点存在性

`touchHidlTest` 的节点表里确实有：

```text
HBP node:[182] path:/proc/touchpanel/report_rate
```

但 RMX5010 的 Synaptics 驱动**没有创建这个 proc 节点**：

```text
/proc/touchpanel/report_rate: No such file or directory
/proc/touchpanel/report_rate_white_list: No such file or directory
/proc/touchpanel/game_mode: No such file or directory
/proc/touchpanel/high_frame_enable: No such file or directory
```

驱动只在 `debug_info/main_register` 里打印固定映射：

```text
report rate(1:120HZ,2:240HZ,3:180HZ): 0
```

### 2.2 写入测试结果

以下方式都试过，HAL/工具都返回 0，但 `main_register` 的档位始终是 0：

```text
touchHidlTest -c wo 0 182 1 / 2 / 3 / 120 / 240
touchHidlTest -c ws 0 182 1 / 2 / 3
touchHidlTest -c wb 0 182 1 / 2 / 3
```

`-c ro 0 182` 读回为空，`-c rb 0 182` 也没有数值。说明这不是“参数写错”，
而是 RMX 触控固件/驱动没有暴露动态 report rate 控制；之前的
`touch rate applied` 日志只代表 HAL 调用返回 0，**不代表实际生效**。

### 2.3 现在的处理

- KSU `touch_rate.sh` 在 `/proc/touchpanel/report_rate` 不存在时直接返回，
  不再把调用成功当成“已应用”；
- `action.sh` 点击时打印 “report_rate is not exposed ... unsupported”；
- Sense 移除可调滑条，改为“触控报告率”诊断行，显示驱动档位/是否支持；
- 设置键 `op13_fix_touch_sampling_rate` 保留，仅作未来驱动支持时的配置位。

### 2.4 结论

RMX5010 上**不能通过软件调触控采样率**；系统/触控固件会按自己的策略切换
（当前档位 0=自动）。如果要改，只能改 vendor 触控固件或 DTS，属于高风险
方向，未做。

> 2026-10-27 更正：提交 `6ed96a0` 里“360→息屏 70→亮屏 360”的记录来自
> `touchHidlTest` 返回值和模块日志，并没有读回驱动实际档位；后续用
> `debug_info/main_register` 复核发现档位始终为 0，所以那是一次误判。
> 当前实现不再把“HAL 返回 0”写成“已应用”。

## 3. LHDC V5

### 3.1 问题定位

- HyperOS `com.android.bt` APEX 的 `libbluetooth_jni.so` 已声明 LHDC V5
  （`dumpsys bluetooth_manager` 中 `LHDC V5: 8004`）。
- 但设备上 **没有任何 `liblhdcv5.so` / `liblhdcv5BT_enc.so`**，即只有编解码
  框架、没有编码器后端；连接 LHDC 耳机时会失败或回退。
- OP13 的 `lhdc_patch.cpp` 是自包含的 ARM64 原生桥：扫描已加载的
  `libbluetooth_jni.so`，验证 stub/接口表，再替换为随 APK 打包的 Savitech
  软件编码器，并把 V5 包间隔从 20 ms 改成 10 ms。

### 3.2 移植

- 源码：`lsposed-src/native/lhdc_patch.cpp`（从 OP13 版本移植，JNI 符号改为
  `Java_local_mio_gt7profodfix_BluetoothHooks_nativeApplyLhdcPatch`）。
- 编译（NDK r28c）：

```bash
NDK=/d/AndroidSDK/ndk-r28c/android-ndk-r28c/toolchains/llvm/prebuilt/windows-x86_64/bin
"$NDK/aarch64-linux-android35-clang++.cmd" -shared -fPIC -O2 -std=c++17 \
  -static-libstdc++ -llog -ldl -latomic \
  -o lsposed-src/libs/arm64-v8a/libop13_lhdc_patch.so \
  lsposed-src/native/lhdc_patch.cpp
```

- 打包：`lsposed-src/libs/arm64-v8a/` 下的
  `libop13_lhdc_patch.so`、`liblhdcv5.so`、`liblhdcv5BT_enc.so` 由
  `build_apk.sh` 放入 APK 的 `lib/arm64-v8a/`；
  `AndroidManifest.xml` 设置 `android:extractNativeLibs="true"`。

- 2026-10-27 合并到 Sense 后：三个 `.so` 已复制到
  `Sense/app/src/main/jniLibs/arm64-v8a/`，Sense 的 `app/build.gradle`
  设置 `packaging.jniLibs.useLegacyPackaging = true`；`BluetoothHooks`
  优先从 `com.zephiel.sense` 的 `nativeLibraryDir` 加载
  `libop13_lhdc_patch.so`，并保留 `local.mio.gt7profodfix` 回退。
  JNI 符号仍匹配（Java 包名未改）。重启后实测 `status=7`、
  `LHDC V5 software encoder interface installed`。
- 作用域：LSPosed 需包含 `com.android.bluetooth`。本次用
  `tools/lspd`（app_process + SQLiteDatabase）写入：

```text
scope=com.android.bluetooth
scope=com.android.systemui
scope=com.xiaomi.finddevice
scope=org.ifaa.aidl.manager
scope=system
```

（也可以在 LSPosed 管理器里手动勾选；不要直接改正在运行的 WAL 数据库，
本次是在 root 下通过 SQLiteDatabase 写入后重启验证。）

- `BluetoothHooks` 在 `AdapterService.onCreate/onStartCommand` 后加载
  `libop13_lhdc_patch.so`，先调用 `nativeProbeLhdc()`（加载两个编码库并检查
  `lhdcv5BT_get_handle/init_encoder/encode`），再调用
  `nativeApplyLhdcPatch()`。

### 3.3 实测

```text
RMX5010HyperOSFix: Bluetooth entry, installing LHDC V5 bridge
RMX5010HyperOSFix: Bluetooth LHDC lifecycle hooks=3
RMX5010HyperOSFix: LHDC V5 packaged libraries status=7
RMX5010HyperOSFix: LHDC V5 software encoder interface installed
```

`status=7` = 核心库 + wrapper 库 + 三个必需符号全部通过。蓝牙进程保持运行
（`State: ON`），未崩溃。

**尚未验证**：当前没有配对 LHDC V5 耳机，真实播放、重连、通话/录音、音量
面板都未测。如果未来 OS 更新改变了 `libbluetooth_jni.so`，helper 会返回
负状态（-1/-2/-3）并跳过，不会强行打补丁。

## 4. 复现与回退

```bash
# 触感强度
adb shell su -c 'settings put global op13_fix_haptic_scale 1.0'   # 回退默认
adb shell su -c 'settings delete global op13_fix_haptic_scale'

# 采样率
adb shell su -c 'settings put global op13_fix_touch_sampling_rate 120'
adb shell su -c 'settings delete global op13_fix_touch_sampling_rate'

# LHDC：从 LSPosed 作用域移除 com.android.bluetooth 即可停用；
# 不修改任何系统分区文件。
```

## 5. 结论

触感与采样率已经在 RMX 的 Oplus/Qcom HAL 上落地并通过可量化日志验证；
LHDC 编码器桥接已成功安装，剩余只差一只 LHDC V5 耳机做端到端试听。
