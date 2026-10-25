# GT7 Pro (RMX5010) 传感器映射表 — 对照一加13 OP13HyperOSFix 方案

实测来源:`dumpsys sensorservice`(haotian OS4.0.0.19 + 原厂 16.0.7.201 硬件底,
2026-10-25)。OP13 的 ID 来自其文档 `一加13澎湃OS4综合修复方法.md`。

## 核心对照(OP13 修复项 1-7 所需)

| 功能 | OS4 SystemUI 期望(小米) | OP13 实际(一加13) | **GT7 Pro 实际(实测)** | GT7 Pro 判定 |
|---|---|---|---|---|
| 抬起亮屏 | 33171036 (oem7 Pick Up) | type 22 `pick_up_motion` | **type 22 `pick_up_motion` Wakeup** | ✅ 与 OP13 完全一致(欧加公共栈)——OP13 修法(替换注册+语义翻转 0↔1)可直接套用 |
| FOD 移动检测 | 33171030 (MIUI) | 33171026 `amd_oplus` | **33171026 `amd_oplus` Wakeup** | ✅ 同 OP13——语义映射 2→1(移动)、1→2(稳定) |
| FOD 口袋/NonUI | 33171027 (MIUI 私有) | type 8 距离(wakeup) | **type 8 `tcs3720 Proximity Sensor Wakeup`** ✅ 另有 **33171075 `pocket` Wakeup**(OP13 无此型号对应记录) | 走 type 8(OP13 同款);`pocket`(33171075)是更语义化的候选,需实测值域后二选一 |
| F4 距离防误触 | — | type 8 | **type 8 同上** | ✅ 直接复用 |
| 步数 | wakeup type 18 | non-wakeup type 18 | **type 18 `pedometer Oplus Step_detect` Non-wakeup** | ✅ 同 OP13——`getDefaultSensor(18, true)→false` |

## GT7 Pro 私有传感器全表(实测)

type 22 pick_up_motion(W) | 33171001 rgb | 33171009 free_fall(W) |
33171024 sensor_logger | **33171026 amd_oplus(W)** | 33171028 wise_rgb |
**33171032 lux_aod(W)** | **33171034 pedometer_minute(W)** |
33171036 elevator_detect(W)【注意:OP13 文档里 OS4 期望的"抬起"ID,在本机是电梯检测!】 |
33171037 activity_recognition(W) | 33171044 motion_state_sense |
33171052/54/55/59 rgb/flicker/light/spectral_rear(tcs3449) |
33171061 oplus_measurement | **33171066 gesture_prox(W)** |
**33171067 phone_prox(W)** | 33171068 shaking(W) | **33171075 pocket(W)** |
33171077 backtap(W) | 33171078 rotation(W) | 33171082 lay_detect |
33171084 backclip(W) | 33171092 car_motion
(W)=Wakeup。标准:type 1/3/4/5(BMI26X/AKM/QTI)、**type 8 proximity(tcs3720, W)**、
9/linear/rot/game/grav、**type 18 step_detect(non-wakeup)**、significant_motion、
stationary/motion_detect、device_orient、geomagnetic_rv。

## 关键结论

1. **GT7 Pro 与一加 13 的传感器栈高度同源**(都是欧加 + QTI see 传感器框架):
   抬起(22)/FOD 移动(33171026)/距离(type 8)/步数(non-wakeup 18)四个关键 ID
   **完全一致**——OP13 的 1~5/7 号修复代码可以近乎直接复用,只需换传感器对表常量。
2. 本机特有候选:33171075 `pocket`(语义直给)与 33171032 `lux_aod`(AOD 光照),
   FOD NonUI 优先按 OP13 走 type 8,pocket 作为增强候选。
3. F4(一加侧键自定义键)在 GT7 Pro 上不存在同款硬件键;等价物需查
   `getevent` 确认(可能是 F3/扫光器件或无)。修复项 1/2 的"按键源"待定,
   3/4/5/7 不受影响。
