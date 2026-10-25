# 指纹入口、录入与 FOD 图标：根因链与当前状态（2026-10-26）

## 1. 设置页没有指纹入口 —— 已解决

调用链（全部来自实机反编译校验）：

```
FingerprintEntryPreferenceController.getAvailabilityStatus()
  -> FingerprintHelper.isHardwareDetected()
    -> FingerprintManager.isHardwareDetected()
      -> system_server: Sensor.isHardwareDetected(halInstance)
           = ServiceManager.checkService("<IFingerprint>/<halInstance>") != null
             && FingerprintServiceStub.getInstance().isFpHardwareDetected()
               ->（小米注入的）FingerprintServiceStubImpl.isFpHardwareDetected()
                    SystemProperties.get("persist.vendor.sys.fp.vendor")
                    == "" 或 "none"  =>  false
```

- 该属性在 RMX 上的 SELinux 标签是 `vendor_system_prop`；策略里只有
  `hal_mtdservice_default` / `vendor_qti_init_shell` 能读，**system_server 没有读权限**，
  永远读到空串。
- 在 vendor 策略里给 system_server 加 allow 会触发 Treble neverallow（OS3 实测卡一屏），
  所以直接改小米自己的桩：`FingerprintServiceStubImpl.isFpHardwareDetected()` 恒返回 true
  （与 Oplus 基类 `FingerprintServiceStub` 的行为一致）。
- 工具：`scripts/patch_miui_services_fp_stub.py`，产物用
  `scripts/build_system_ext_patches.sh` 写回 system_ext（同时删除
  `framework/oat/arm64/miui-services.{odex,vdex,art}` 与 `.fsv_meta`）。
- 实机验证：`isHardwareDetected=true`，设置页出现「指纹」。

## 2. 录入秒失败（HW_UNAVAILABLE）—— 已解决

- 现象日志：`FingerprintCallback: sendErrorResult errMsgId=1` →
  `Sensor: Fingerprint sensor hardware unavailable.`
- 根因：UFF HAL 校准闸 `vendor.fingerprint.cali` 为空（OS3 时代同一坑）。
- 修复：odm build.prop（`/odm/build.prop` 与 `/odm/etc/build.prop`）写入
  `vendor.fingerprint.cali=1`，vendor_init 对该属性类型（vendor_default_prop）有 set 权限。
- 实机验证：可正常录入。

## 3. FOD 图标 / 指纹类型 —— 已解决

**最终根因**：`ro.hardware.fp.fod`、`ro.hardware.fp.fod.c` 在真机上被 Realme 的
`property_contexts` 按 `ro.hardware.` 前缀标成 `vendor_default_prop`，而 Settings/SystemUI
（system_app）对该类型没有 file read 权限，读到的值是空 → `MiuiConfigs.GXZW_SENSOR=false`
→ 系统走“非屏下（home 键）”UI，也不创建 FOD 图标视图。

**修复**：在 vendor_property_contexts 里把这几个名字精确映射到 `vendor_frc_prop`
（vendor_init 可写、system_app/system_server 可读）。重启后：

- `getprop -Z ro.hardware.fp.fod` → `u:object_r:vendor_frc_prop:s0`，值 true；
- logcat 出现 `MiuiGxzwManager` 日志，SurfaceFlinger 出现 `VRI-gxzw_anim` / `VRI-gxzw_touch` 层；
- 锁屏底部中央出现指纹光圈，截图实测圆心 ≈ (630, 2150)，与配置 (632, 2146) 一致。

以下是排查过程（保留供参考）：


已做但无效的尝试：

1. 确认特性值正确：`FeatureParser.support_fod=true`、`front_fingerprint_sensor=true`、
   `fod_solution=3`、`ro.hardware.fp.fod(.c)=true`、`persist.vendor.sys.fp.fod.*` 全部就位。
2. 把 `persist.vendor.sys.fp.fod.*` 与 `persist.vendor.sys.fp.vendor` 从
   `vendor_system_prop` 重标到 `vendor_frc_prop`（system_server/system_app 均可读，
   vendor_init 可写）。重启后标签、值、无 avc 拒绝均确认。
3. 设置 `gxzw_icon_show_enable=1`、`gxzw_icon_aod_show_enable=1`；
   `ro.hardware.fp.fod.location=low` 并重启 SystemUI。
4. 重启 SystemUI、锁屏/唤醒反复截图：锁屏底部始终没有指纹光圈。

当前证据/线索：

- `MiuiConfigs.GXZW_SENSOR = SystemProperties.getBoolean("ro.hardware.fp.fod", false)`
  → 理论为 true；`MiuiFingerPrintFactory.getFingerPrintManager()` 据此应返回
  `MiuiGxzwManager`。
- **但整个 logcat 没有任何 `MiuiGxzwManager` 的日志**（`showGxzwView` 入口有 Log.i），
  说明该 manager 没有被创建/没有被调用。
- `AODUpdatePositionController`（代码在 MIUIAod.apk，运行时在 SystemUI 进程）打印
  `mGxzwIconX 0 mGxzwIconY 0`、`mIsGxzwIconShow: false` —— 图标位置未取到。
- `MiuiGxzwUtils.caculateGxzwIconSize()` 直接读
  `persist.vendor.sys.fp.fod.location.X_Y` / `size.width_height`；若读空则不更新
  `GXZW_ICON_X/Y`（保持 0）。
- 待查：SystemUI 进程（system_app）实际读这两个属性是否为空；若是，需要在
  property contexts 中换一个 **platform_app/system_app/system_server 都可读** 的类型，
  或补 vendor 侧 allow（需避免 Treble neverallow）。
- 另一个待查点：`MiuiFingerPrintFactory` 的调用方在 `AwesomeLockScreen`/`LockScreenRoot`，
  需确认 HyperOS 4 的锁屏（all-in-one clock）是否仍走这条路径。

## 4. 本轮实刷镜像

- `system_ext_fp_entry.img` sha256 `f2a38f2bd78cb3343dd56763068475587b6641736ab438eedc3a5036b6d443ba`
  （Settings 人脸修复 + miui-services 指纹桩修复）
- `odm_fp2.img` sha256 `e193f3f15ac801712d4f78f28c34098a31c6056d27a82a07b6901e249e072903`
  （指纹 HAL 替换 + vendor.fingerprint.cali=1）
- `vendor_fp2.img` sha256 `e53746ae086414b4c912a5361b07452762385c7fed7e3a1edea02b9b6db5d113`
  （FOD 属性重标 vendor_frc_prop + 权限 XML）
