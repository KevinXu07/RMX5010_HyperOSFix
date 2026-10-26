# 触感 / 触控采样率 / LHDC：RMX5010 适配记录

状态（2026-10-26）：

| 项目 | 状态 |
|---|---|
| 触感私有效果映射 + 支持列表扩展 | ✅ 实机加载（map=1/info=1） |
| RMX 触感强度系数 | ✅ 实测 0.7 生效（scale=0.70，Step 振幅 0.70） |
| 触控采样率节点 182 + 亮灭屏切换 | ✅ 实机日志验证（360→息屏 70→亮屏 360） |
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

### 1.5 仍未做的部分

- MIUI_SDK 的 75 ms 键盘 Step 本身还没有按 RMX 马达缩短。要改波形需要在
  `VibratorManagerService` 的 usage 边界重建 `VibrationEffect`，属于下一步
  手感调参；当前先用强度系数解决“过冲/过强”。
- OP13 的全局触感滑条、MiRemix、视频触感、通知长按/清理/指纹成功失败等
  RTP 功能依赖 `IOplusVibrator` 和小米 RTP 资源，在 RMX 上不可直接复用。
- 指纹成功/失败触感需要至少一枚已录指纹才能实机验证。

## 2. 触控采样率

### 2.1 接口确认

RMX 的 `touchHidlTest` 节点表：

```text
HBP node:[182] path:/proc/touchpanel/report_rate
```

与 OP13 使用的节点号完全一致。写入方式：

```bash
/odm/bin/touchHidlTest -c wo 0 182 <70|120|180|240|360>
```

`wo` 走 `vendor.oplus.hardware.touch.IOplusTouch` AIDL；`rc=0` 表示 HAL 接受。
`/proc/touchpanel/report_rate` 不是普通可读文件，读值需要通过实际触控事件
统计，因此当前以 HAL 写入返回值和亮灭屏行为作为验证依据。

### 2.2 实现

- `kernel-src/ksu-module/touch_rate.sh`：读取设置键，写节点 182；
- `kernel-src/ksu-module/action.sh`：KernelSU 模块动作，点击一次循环
  `70 → 120 → 180 → 240 → 360 → 70`，立即写入并打印当前档位；
- `service.sh`：开机 source `touch_rate.sh`，每 5 秒看
  `/sys/class/backlight/panel0-backlight/brightness`，亮屏应用所选档位，
  息屏时对 180/240/360 写 70 Hz（120 及以下保持）；
- 设置键：

```bash
adb shell settings put global op13_fix_touch_sampling_rate 120
```

最终设备默认：**120 Hz**（保守，接近 OP13 默认；需要时可点 KSU 模块动作切到
240/360）。

### 2.3 实测

```text
touch rate applied: 120 Hz
settings put global op13_fix_touch_sampling_rate 360
touch rate screen off: 70 Hz
touch rate applied: 360 Hz     # 亮屏
```

KSU action 实测：

```text
action: touch rate unset -> 120
action: touch rate 120 -> 180
action: touch rate 180 -> 240
```

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
