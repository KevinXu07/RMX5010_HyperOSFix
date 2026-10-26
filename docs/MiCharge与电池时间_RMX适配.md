# MiCharge / 手机管家电池时间：RMX5010 适配

状态（2026-10-26）：

- **电池页可用时长已实测修复**：手机管家“省电与电池”从 `0` 变为
  **36 时 36 分**，日志 `discharge 0ms -> 131800000ms`。
- MiCharge 框架桥、SystemUI W MAX 展示、SecurityCenter/Manager 钩子均已加载。
- **充电中的“预计充满时间”和充电小数/W MAX 实机展示尚未验证**：测试时设备
  电量 100%、状态 Full，且通过 ADB 连接，无法拔插充电器做完整充电回归。

## 1. 设备事实

```text
com.miui.securitycenter   13.5.8-260908.0.1  targetSdk 36
com.miui.securitymanager  21.0               targetSdk 36
com.android.systemui      17.03.260226.r
IMiCharge                 /system_ext/framework/miui-services.jar
充电 HAL                  vendor.oplus.hardware.charger.ICharger/default
```

RMX 的 Oplus 充电节点存在：

```text
/sys/class/oplus_chg/battery/
/sys/class/oplus_chg/usb/
/sys/class/oplus_chg/wireless/
/sys/class/power_supply/battery/{capacity,current_now,voltage_now,status,temp}
/sys/class/power_supply/battery/{time_to_full_now,time_to_full_avg,time_to_empty_avg}
```

测试时：

```text
capacity=100  status=Full  current_now=0  voltage_now=4470000
time_to_full_now=0  time_to_full_avg=0  time_to_empty_avg=3600
```

后三个是 ColorOS 的“不支持估算”占位值；原手机管家会把它们当成 0/1 分。

## 2. 移植内容

从 OP13 模块移植并按 RMX 包名/类名适配：

| 文件 | 作用 |
|---|---|
| `MiChargeFrameworkBridge.java` | system_server 内桥接 Oplus charger HAL / sysfs，向 `IMiCharge` 提供快充类型、功率、小数电量 |
| `MiChargeHooks.java` | SystemUI 充电状态、SecurityCenter/Manager 的 `IMiCharge`、电池页字段直读 |
| `MiChargePresentationHooks.java` | Xiaomi W MAX / 双电芯展示，不替换原有充电模型 |
| `SecurityCenterTimeHooks.java` | 电池页可用时长/预计充满时间 |

安装点：

```text
SystemServerHooks.install  -> MiChargeFrameworkBridge.install(loader)
SystemUiHooks.install      -> MiChargePresentationHooks.install(loader)
HookEntry(securitycenter/manager) -> MiChargeHooks.install(pkg, process, loader)
```

LSPosed scope 需要：

```text
system
com.android.systemui
com.miui.securitycenter
com.miui.securitymanager
```

## 3. 实测日志

```text
MiCharge framework bridge installed: getters=5, receivers=6, uevents=1
MiCharge framework bridge active
MiCharge W MAX presentation installed: properties=1, settings=2, controllers=1, closedUi=1, models=1
Security Center IMiCharge hooks active
RMX5010BatteryTime: discharge 0ms -> 131800000ms
```

电池页实测：

```text
预计亮屏可用时长：36 时 36 分
剩余电量：100%
使用时长：0 时 34 分（本次开机后的实际使用时长）
```

说明 `SecurityCenterTimeHooks` 已经替换了错误的 0/1 分估算。

## 4. 还没验证

1. **充电中的预计充满时间**：需要拔掉 ADB、插上充电器，观察页面从占位
   值变成实际估算。
2. **充电小数电量 / 状态栏 / 超级岛 / W MAX**：需要真实充电头和充电线；
   `persist.vendor.accelerate.charge` 与 `key_fast_charge_enabled` 的 W MAX
   展示钩子已安装，但未在 RMX 充电曲线上验证。
3. **OP13 的 UFCS 100W profile**：RMX 的 devicetree 节点名不同，当前读取会
   尝试 OnePlus `silicon_p_770` 路径并回退到 sysfs；实际功率仍以 Oplus
   charger HAL 为准。若后续要精确 W 数，需要按 RMX 的 UFCS 节点重新映射。

## 5. 回退

- 不需要时从 LSPosed 作用域移除 `com.miui.securitycenter` /
  `com.miui.securitymanager`，或停用模块，即可恢复原手机管家行为。
- 本修复不修改任何系统 APK、framework 或分区文件。

## 6. 结论

电池页“可用时长”已从明显错误的 0/1 分修复到真实估算；MiCharge 的框架和
展示层已就位。充电中的完整回归需要用户插拔充电器完成，在此之前不应宣称
“充电显示已完全修复”。
