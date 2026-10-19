# patches/auto-brightness — 自动亮度失效修复（删 high_pwm_rgb prop）

## 症状

自动亮度开关可开但不生效：环境光变化时屏幕亮度纹丝不动，只能手动拖条。
`dumpsys display` 里 `mLightSensor=null`、`mAmbientLux=-1.0`、`shouldListenToLightSensor=false`。

## 根因（实机 + 反汇编双重确认）

本机前置环境光传感器是 **ams-OSRAM TCS3720**（RGB+ALS 一体，屏下）。HyperOS 里
`sensors.qsh.so`（/vendor/lib64）内置两套光照管线，由 odm 属性
`ro.vendor.oplus.sensor.high_pwm_rgb` 在模块初始化时切换：

| prop 值 | 走的路径 | 注册的传感器 |
|---|---|---|
| `true`（出厂值） | `oplus_high_pwm_light` / `oplus_high_pwm_cct` 模块 | `qti.sensor.high_pwm_rgb`(33171070) + `qti.sensor.high_pwm_cct`(33171074) |
| 非 `true`（`false` / 删除） | `oplus_ambient_light` 模块 | **`android.sensor.light` (type 5)** + `wise_light` |

反汇编证据（`sensors_qsh.so`）：

- `oplus_high_pwm_light_module_init`（vaddr 0x41a04）：prop=="true" 才注册
  `0x1fa267e`（=33171070）并订阅 `wise_rgb`/`fold_fusion_light`；否则只打
  `support_type 0` 日志直接返回。
- `oplus_high_pwm_cct_module_init`（0x417f0）：同构，注册 `0x1fa2682`（=33171074）。
- `oplus_ambient_light_module_init`（0x403e8）：prop=="true" 时只打 `support_type 0`
  直接返回；**其他一切值（false / 取不到 prop）都注册 type 5**（0x404f4 `mov w0,#5`）
  并订阅 `ambient_light`/`wise_light`/`wise_rgb`/`fold_fusion_light` 四个 suid。

Android 自动亮度（`AutomaticBrightnessController`）只认 **TYPE_LIGHT=5**。
出厂 prop=true → 只有 OPLUS 私有类型上线 → `mLightSensor` 永远 null → 自动亮度死。

实机验证（2026-10-19，acbefdc7）：

```
resetprop ro.vendor.oplus.sensor.high_pwm_rgb false   # 或 resetprop ... ""
kill -9 <sensors-service-multihal pid>                 # 重启 HAL
dumpsys sensorservice | grep "android.sensor.light"
# → tcs3720 Oplus Ambient Light Sensor  type: android.sensor.light(5)  ✅
dumpsys display | grep mLightSensor
# → mLightSensor={Sensor name="tcs3720 Oplus Ambient Light Sensor Non-wakeup", type=5, ...} ✅
# logcat: AutomaticBrightnessController: updateAutoBrightness ... mAmbientLux=0.3125 ✅
# AutomaticBrightnessStrategy 接管，lux→nits 曲线（brightness-overlay 已带）正常工作 ✅
```

## 修法（载荷）

镜像里**删掉** odm build.prop 中的一行：

```properties
# odm/build.prop 与 odm/etc/build.prop 同步删除：
-ro.vendor.oplus.sensor.high_pwm_rgb=true
```

本仓库 `patches/odm-identity/odm_build.prop`（odm 分区 prop 载荷）第 32 行已同步删除
——**该补丁曾把这行原样带进了移植包，属于移植引入的回归**，ColorOS 原厂它是对的、
HyperOS 下必须去掉。

> 注意：prop 是 `ro.*` 只读属性，开机动画前就已固化，**改文件后必须整分区重刷**
> （EROFS rebuild 或按 `docs/SELinux闭包与EROFS重建规范.md` 走 mkfs.erofs 流程），
> 不能靠 resetprop 长期生效——resetprop 只对 `ro.vendor.oplus.sensor.*` 这类非 persist
> key 改内存值，重启即还原。

## 不需要做的事（对照网传"自动亮度方案"逐条核对）

| 网传步骤 | 本机结论 |
|---|---|
| ① 删 odm build.prop 的 `high_pwm_rgb` | ✅ **就是本补丁**（唯一有效步骤） |
| ② vendor/etc/displayconfig → product | ❌ vendor 里 5 个文件（4×7366B + 1×2674B）**没有 autoBrightness 块**，复制反而降级 |
| ③ dumpsys display 取 uniqueId | 已知：`local:4630947008615494291`，product 里已有同名文件 |
| ④ 最大文件改名成屏幕 id | ❌ product 已有 `display_id_4630947008615494291.xml`（brightness-overlay 补丁，带完整 `<autoBrightness>` + lux 曲线 + HBM） |

即：②③④ 对本机是**无效甚至有害**步骤，真正的卡点只有 ①。

## 已知边界

- 光感读数链路：tcs3720 wise_rgb 原始计数 → HAL `oplus_light_iface` → type5 事件。
  实测室内弱光 lux 读数约 0.06–0.4（raw 计数 16–48），量级合理但**未做高照度回归**
  （强光手电/户外验证待补）。`/odm/etc/sensor/sensor_light_para.json`（HAL
  `updata_light_para` 读取的调参文件：lux_coef_{L,H,Super}ir、golden_param、line_para 等）
  在设备上不存在——ColorOS 原厂也没有，疑似只影响 lb_algo 精调路径，不影响基本 lux 上报。
- `ro.vendor.oplus.sensor.brl_receive`/`lb_algo`/`use_black_mode` 三个 prop 保留原值；
  删掉 high_pwm_rgb 后 `high_pwm_*` 两个传感器消失，依赖它们的 MIUI 组件
  （NetworkBoost.StatusManager、wifi MotionTracker、DeviceStaticStateDetectSensor）
  会订不到该传感器，均属无关紧要的后台遥测。
