# Sense 作为唯一 LSPosed 模块：改动清单

状态（2026-10-27）：已实机验证。

## 1. 最终结构

```text
KernelSU  rmx5010_fod_bridge（显示名 RMX5010 HyperOS Fix，1.1.0）
          根脚本、FOD 桥、双击亮屏、触控采样率、音频 bind mount、
          IFAA SELinux、钱包锁屏 AppOp、ctl.sh/status.conf
LSPosed   com.zephiel.sense（唯一模块）
          Sense UI + RMX5010 主 hooks + ColorOS 钱包 hooks
```

旧的 `local.mio.gt7profodfix` 和 `local.mio.coloroswalletcompat` 不再安装；
两者同时存在会导致 hook 重复执行。

## 2. Sense 源码改动

Sense 源码目录：`E:\code\modify\Sense`（不在本仓库 git 内）。

### 2.1 新增/复制

```text
app/src/main/java/local/mio/gt7profodfix/*.java
    从 RMX5010_HyperOSFix/lsposed-src/java 复制（17 个文件）
app/src/main/java/local/mio/coloroswalletcompat/*.kt
    从 COS-WALLET-FIX 复制（4 个文件，MIT）
app/src/main/java/com/zephiel/sense/xposed/SenseXposedEntry.kt
    统一入口：initZygote -> 钱包；handleLoadPackage -> 主 hooks + 钱包
app/src/main/assets/xposed_init
    com.zephiel.sense.xposed.SenseXposedEntry
app/src/main/assets/oplus-fwk.jar
    钱包模块原本的 OPlus framework 资源
app/src/main/jniLibs/arm64-v8a/liblhdcv5.so
app/src/main/jniLibs/arm64-v8a/liblhdcv5BT_enc.so
app/src/main/jniLibs/arm64-v8a/libop13_lhdc_patch.so
```

### 2.2 Manifest

```xml
<permission android:name="oplus.permission.OPLUS_COMPONENT_SAFE"
    android:protectionLevel="dangerous" />

<application ...>
    <meta-data android:name="xposedmodule" android:value="true" />
    <meta-data android:name="xposeddescription"
        android:value="RMX5010 HyperOS 移植修复与 ColorOS 钱包兼容" />
    <meta-data android:name="xposedminversion" android:value="93" />
    <meta-data android:name="xposedscope" android:resource="@array/xposedscope" />
    <meta-data android:name="xposedinit"
        android:value="com.zephiel.sense.xposed.SenseXposedEntry" />
</application>
```

`res/values/arrays.xml` 的 `xposedscope` 包含：

```text
android, system, com.android.systemui, com.android.bluetooth,
com.android.settings, com.miui.securitymanager, com.miui.securitycenter,
org.ifaa.aidl.manager, com.xiaomi.finddevice, com.android.nfc,
com.android.se, com.finshell.wallet, com.heytap.tas,
com.unionpay.tsmservice, com.oplus.eid, com.miui.tsmclient
```

### 2.3 Gradle

```groovy
android {
    packaging {
        jniLibs { useLegacyPackaging = true }
    }
}
```

LHDC 代码按绝对路径从 `ApplicationInfo.nativeLibraryDir` 加载
`libop13_lhdc_patch.so`，所以 .so 必须解压安装。

### 2.4 UI / 配置

```text
SettingsActivity.kt        系统增强 + 移植修复 + 交互体验
SettingsViewModel.kt       状态、触感、IFAA、钱包测试、刷新率、调度
ModuleControlManager.java  KSU ctl.sh / Settings.Global 契约
strings.xml                新增文案
```

2026-10-27 清理/新增：

- 移除自动高亮补光（超声波指纹不需要）；
- 移除物理按键映射（RMX 没有额外按键）；
- 移除线性马达 `sys.haptic.*` 实验入口；
- 移除日常/游戏触控采样率滑条，改为只读诊断；
- 抬起唤醒开关直接读写系统 `pick_up_gesture_wakeup_mode`；
- 新增屏幕刷新率 120/60Hz（`user_refresh_rate`）；
- 新增性能调度预设（`powersave` / `schedutil` / `performance`）；
- 新增“测试触感”按钮和 1.35 次幂触感曲线。

写入的模块键：

```text
op13_fix_haptic_scale
op13_fix_ifaa_model
```

### 2.5 冲突/限制

- `TouchEnhanceManager` 已不再启动；RMX 驱动没有
  `/proc/touchpanel/report_rate`，KSU `touch_rate.sh` 检测到后跳过，
  不再把 HAL 返回 0 当成实际生效。
- `LiftToWakeManager` 已不再启动；系统开关 + LSP `SystemUiHooks` 负责实际
  抬起唤醒。
- `VibrationManager` 已不再启动；只保留模块触感强度。
- 一加 13 的 `op13_scene_sched` 内核模块在 RMX 上不存在，完整场景调度/
  FAS/线程放置没有移植；Sense 只提供 CPU governor 预设。

## 3. 构建与安装

```bash
cd RMX5010_HyperOSFix
./scripts/build_sense_module.sh       # release, 非 debuggable，默认用 debug keystore 签名
./scripts/register_sense_lsposed.sh
adb install -r out/Sense-RMX5010.apk
adb reboot
```

钱包套件可以用 `scripts/install_cos_wallet.sh` 一次安装（会调用 Sense 安装
和 scope 注册，并放行 AppOp 10020）。

## 4. 实机验证

- SukiSU 授权 Sense（UID 10318）；不需要 KernelSU 管理器。
- 重启后 LSPosed 日志中所有作用域进程都显示
  `[com.zephiel.sense,...]`。
- `system_server hooks installed`、`SystemUI hooks installed`、
  `wallet gesture -> FinShell swipe hook installed`、
  `ColorOSWalletCompat: ...`、`LHDC V5 software encoder interface installed`。
- 锁屏/解锁双击电源键均进入 `NfcConsumeActivity`；锁屏页面覆盖 Keyguard。
- Sense“移植修复”页显示 `KSU 1.1.0 · LSP 已激活`，并能执行重新应用。

## 5. 注意事项

- Sense 现有安装如果和新 APK 签名不同，`adb install -r` 会失败；需要先卸载
  Sense（会清设置）。
- 卸载重装钱包包后，LSPosed 可能清掉 scope；重跑
  `register_sense_lsposed.sh` 并重启。
- 旧模块 APK 和 LSPosed DB 备份在
  `E:\code\modify\haotian_work\sense_migration\` 与
  `/data/local/tmp/modules_config.db.before_sense`。
- 钱包 Kotlin 代码来自 MIT 许可的 COS-WALLET-FIX；分发 Sense 时需要保留其
  版权与许可声明。
