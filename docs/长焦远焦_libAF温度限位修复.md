# 长焦远处对不上焦：libAF 温度偏移把远端限位拉近（2026-11-11）

## 症状
- 3× 潜望长焦：1 米左右清晰，几米外一律发虚；自动对焦和专业模式手动拉到 ∞ 都一样。
- 用户旁证：在 ColorOS 上删掉温控（horae）后，长焦同样对不上远处。

## 证据（实机，haotian h19 底，模块 1.7.5 + Sense 1.45 诊断）
| 场景 | 长焦 DAC | HAL 对焦距离 | 画面 |
|---|---|---|---|
| 1 m 背包，自动对焦 | — | — | 清晰 |
| ~5 m 门，3×/6×/17×，自动或手动 ∞ | 466～473（逻辑位 459，三次一字不差） | 0.66～0.69 dpt（≈1.5 m） | 发虚 |
| 同场景，farLimit 放到 1000 | 398 | 0.365 dpt | 清晰 |
| 同场景，**仅去掉 farLimit 的温度偏移**（最终补丁） | 383～390 | 0.32～0.34 dpt | 清晰（10× 可读正文） |

出厂校准 `/mnt/vendor/persist/camera/rear_third_camera_af_code.json`：无穷远 DAC 297、微距 817。
DAC 读数来自结果 tag `com.oplus.af.dac.value` / `com.oplus.engineercamera.physical.get.af.dac.value`（诊断 hook 源码留在 `E:/code/modify/camwork/libaf/diag/`）。

## 根因
`/odm/lib64/libAF.so`（欧加 AF 核心，md5 `b39b7173…`）：

- `0x3b6e0`（日志 `Set Focus Limit,focusMode…`）从调参读 near/far/default（`tune+0x7c/0x80/0x84`）存到 AF 状态 `+0x90/+0x94/+0x98`；
  满足温度条件时把 default 与 **far** 交给 `0x41128`（`TemperatureOffset`，按 -60～45°C 分段插值的镜头/传感器温度模型）并写回。
- `0x6a8c0`：最终镜头位置 = `min(目标 + 重力下垂补偿, farLimit)`，far 是逻辑位置上界（逻辑位越大越远，DAC 越小越远）。

移植环境下温度模型的输入不对，`TemperatureOffset` 把 farLimit 往近处拉了约 170 逻辑步，镜头到不了无穷远。

已排除：Sense 相机 hook、`camera_unit_config`（与设备原厂 0 差异）、ODM prop 链、HAL SELinux、长焦 PD 缓存、`/proc/shell-temp`（写 36°C 无效）、
App 下发 `com.oplus.phone.temperature`（Sense 1.44 强发后无效）、`persist.camera.OplusCtrlLenspos`（量产版不生效）。

## 修复
- `scripts/patch_libaf_farlimit.py`：`0x3b838 str w0,[x8,#0x94]` → `nop`（文件偏移 0x2b838），只跳过 farLimit 的温度偏移写回；
  near、default、重力补偿、PDAF 不变。输出 md5 `aeaa3fc8…`。
- 载荷：`kernel-src/ksu-module/camera/odm/lib64/libAF.so`，随现有 `/odm/lib64` overlay 下发；
  `camera_fix.sh` 单独把它的标签设回原厂 `vendor_file`（由 camera provider 加载，不是 app）。模块 1.7.7 (44)。
- Sense 1.46：保留 `CameraThermalHooks`（`OplusHoraeThermalHelper.getCurrentThermal` 由桩值 -1 改为电池温度，恢复 App 原厂温度来源），与长焦限位无关。

## 刷入 1.7.7 后复验（2026-11-11，整机重启后）
- 系统状态：模块 1.7.7 (44)；`/odm/lib64/libAF.so` md5 `aeaa3fc8…`，标签 `vendor_file`，camera provider 加载的就是补丁版；Enforcing；5 个摄像头都在；Sense 1.46。
- 实拍结果：

| 场景 | 变焦 | libAF 逻辑位（afWarmStartCamera_3） | 画面 |
|---|---|---|---|
| ~5 m 门 | ~6×（144mm） | 562（修复前 459） | 清晰，纸面正文、TP-LINK 字样可读 |
| 1 m 背包 | 3× | 70（修复前 99，同一近端区间） | 清晰，网眼布纹、徽标文字可读 |

## 残余风险 / 未验证
- 去掉的是 far 端温度补偿：极端温度下远端可能略超无穷远，PDAF 收敛不受影响，但全程扫描会多走一点行程。
- 远端（~5 m）和 1 米近摄已经复验过；暗光、视频、0.6×/1×/2×、人像等模式还没逐项回归。
- 更理想的修法是补上 libAF 温度模型的真实输入（来源尚未定位）；换底包或换 libAF 版本时必须按 md5 重新核对补丁点。
