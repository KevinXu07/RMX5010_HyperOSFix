# 触感 / 触控采样率 / LHDC：RMX5010 适配记录

状态（2026-10-26）：

| 项目 | 状态 |
|---|---|
| 触感私有效果映射 + 支持列表扩展 | ✅ 实机加载（map=1/info=1） |
| RMX 触感强度系数 | ✅ 实测 0.7 生效（scale=0.70，Step 振幅 0.70） |
| 触控采样率节点 182 + 亮灭屏切换 | ✅ 实机：touchDaemon 两个 report_rate 配置开关启用后，120/180/240/360Hz 切换生效 |
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

- OP13 的全局触感滑条、MiRemix、视频触感、通知长按/清理/指纹成功失败等
  RTP 功能依赖 `IOplusVibrator` 和小米 RTP 资源，在 RMX 上不可直接复用。
- 指纹成功/失败触感需要至少一枚已录指纹才能实机验证。

### 1.6 2026-10-30：键盘/触控 Step 波形修正（参考一加13）

问题不是振幅。继续往 HAL/驱动层看，真实 Sogou 键盘一次按键下发的是：

```text
[Step=0ms, Step=45ms(amp 0.74), Step=67ms(off), Step=79ms(amp 0.74)]
总长 191–231ms，reason=TAG=pattern_vibration;keyword=MIUI_SDK
```

这不是单个 75ms Step，而是双脉冲持续驱动。HAL 日志对应两次
`aidl_vibrator: Vibrator on for timeoutMs: 45/79`，驱动侧是恒定数据 +
固定 brake（约 5.7–14ms），所以打字仍然像转子/双敲。之前只按
30–90ms 单步过滤，整段 191ms pattern 根本没被改写。

底层组件：

- AIDL `android.hardware.vibrator.IVibrator/default` 由
  `vendor.oplus.hardware.vibrator-service` 提供，服务环境是
  `RICHTAP_DEVICE_PATH=/dev/awinic_haptic`；
- 预置 effect 0..5 走 809 校准数据：
  `perform effect 2` → `custom data 2 length 448, play-rate 24000 Hz`，
  `perform effect 4` → `length 395`，effect 5 → `length 1454`，
  并带 Vmax/brake 参数。`/odm/etc/vibrator/809/def/effect_*.bin` 是
  8-bit/24kHz 的平滑包络波形，不是恒定正弦。

参考 `os4/external/OP13HyperOSFix/upstream/oneplus13_hyper_haptics_0.8.8`
在 system_server 下发 HAL 前改写效果的做法，RMX 这边改为：

- `HapticHooks.hookTouchStepEffects()` hook
  `VibratorManagerService.vibrateInternal`；
- 对 `reason` 含 `MIUI_SDK` 或 `pattern_vibration` 的整段 pattern
  （实测键盘 191ms），以及普通 30–90ms 单 Step，
  默认替换为 **校准预置 effect 2（TICK，448B@24kHz）**；
- 可通过 `op13_fix_haptic_click_effect` 切换：
  - `2` = TICK（默认，短促）
  - `4` = POP（稍厚）
  - `5` = HEAVY_CLICK（更重）
  - `-1` = 回退 12ms 裸 Step
- 只按 reason/时长过滤，不依赖 OEM 的 usage 编号（实际键盘在 dumpsys
  里显示为 usage UNKNOWN）。

实测：

```text
真实 Sogou 按键：
→ haptic touch step 191ms -> effect=2 (usage=0)
→ played: Prebaked=TICK(MEDIUM, with fallback)
→ aidl_vibrator: Vibrator perform effect 2
→ qcom-hv-haptics: custom data 2 length 448, play-rate 24000 Hz

settings put global op13_fix_haptic_click_effect 4
→ played: Prebaked=POP(...)
```

Sense APK 已重新构建并安装，system_server 日志：
`haptic compatibility active: map=1 info=1 scale=1 click=1`。
默认 `2`；想更厚可切 `4`，想更重切 `5`，想对比旧方案切 `-1`。



## 2. 触控采样率（已修复）

### 2.1 根因

`touchHidlTest` 的节点表一直有：

```text
HBP node:[182] path:/proc/touchpanel/report_rate
```

但写 `touchHidlTest -c wo 0 182 <Hz>` 返回 0 后，驱动档位并不变化。根因不在
HAL，而在 `touchDaemon` 读取的
`/data/vendor/touchconfig/sys_touch_function_feature_config.xml`：

```text
report_rate_white_list_support       默认 false
game_mode_divided_report_rate_support 默认 false
→ gameModeDividedReportRateSupport false, REPORT_RATE_NODE not support
```

ODM 里的 `/odm/firmware/tp/24600/sys_touch_function_feature_config.xml`
版本与 data 配置相同（2025070901），且同样没有这两个开关；所以 data 配置
即使改了也不会被选中。把 data 配置版本抬高并加上两个开关后，节点 182
立刻变成可写。

### 2.2 模块实现

KSU 模块新增：

```text
kernel-src/ksu-module/touch/sys_touch_function_feature_config.xml
    两块 panel（SAMSUNG/BOE）的 TouchConfig 都加：
    report_rate_white_list_support=1
    game_mode_divided_report_rate_support=1
    version=2025070999
kernel-src/ksu-module/touch_config.sh
    校验原文件 SHA-256（9b352e16…），备份为 .bak_touchrate，
    覆盖、chown/chmod/restorecon
post-fs-data.sh + service.sh
    开机确保配置；如果 service 阶段才补上，重启一次 touchDaemon
```

原文件不是已知哈希时不会覆盖，避免误伤其它固件版本。

### 2.3 Sense / KSU 控制

- KSU `touch_rate.sh` 只在两个配置开关都存在时才写节点；
- Sense“系统增强”新增“触控采样率”列表：120/180/240/360Hz；
- 选中后写 `op13_fix_touch_sampling_rate`、`op13_fix_touch_owner=module`，
  并立即调用 `touchHidlTest -c wo 0 182 <rate>`；
- `service.sh` 亮屏应用所选档位，息屏写 120Hz（最低支持档），不再写无效的 70。

### 2.4 实机验证

```text
ctl.sh status:
touch_supported=1
touch_driver=...（debug_info 档位）

选 240Hz:
OplusTouchDaemon: frame_rate_parse:set frame rate 240 frame_rate_mode = 3 (actual rate 240)
OplusTouchDaemon: ts_set_frame_rate: Successful to set 3

息屏:
touch rate screen off: 120 Hz
亮屏:
touch rate applied: 240 Hz
```

### 2.5 历史更正

提交 `6ed96a0` 里的“360→息屏 70→亮屏 360”只来自 `touchHidlTest` 返回值和
模块日志，没有读回驱动实际档位，属于误判。现在以 `touchDaemon` 的
`frame_rate_parse` / `ts_set_frame_rate` 日志和 `main_register` 档位为准，
并且实机确认了息屏/亮屏切换。

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
