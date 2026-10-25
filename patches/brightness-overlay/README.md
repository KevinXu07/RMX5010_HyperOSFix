# patches/brightness-overlay — 亮度曲线 + 圆角/状态栏高度（改包版）

把 OS3 时代 **KSU 模块 bind-mount** 的那两样，直接固化进 `product.img`，**不需要 root**。

## 1. 亮度：放进原厂 lux→nits 曲线

**载荷**：[display_id_4630947008615494291.xml](display_id_4630947008615494291.xml)（11,871 B）
**目标路径**：`product/etc/displayconfig/display_id_4630947008615494291.xml`

**为什么需要**：donor 的 product 里带的是 `display_id_4630946639341352083.xml`——**另一块屏的 uniqueId**。
本机面板的 uniqueId 是 `local:4630947008615494291`（硬件/DRM 上报，见 device_facts），
所以框架按 id 找文件时**找不到**，自动亮度只能走默认策略，原厂曲线（峰值亮度/HBM 阈值/防抖）全丢。

KSU 模块当年是在 `post-fs-data.sh` 里把这份 XML bind-mount 到这个路径（须早于 system_server 加载 DDC）；
固化进镜像后开机就在，时序更优。

验证：

```bash
adb shell ls -l /product/etc/displayconfig/display_id_4630947008615494291.xml   # 应为 11871 字节
# 行为：遮住/强光照射屏幕，观察自动亮度响应是否回到原厂手感（原厂曲线比 MIUI 默认更跟手）
```

## 2. 圆角 116px + 状态栏高度 160px：换 `DevicesAndroidOverlay.apk`

**载荷**：[DevicesAndroidOverlay.apk](DevicesAndroidOverlay.apk)（10,911 B，target = **android**）
**目标路径**：`product/overlay/DevicesAndroidOverlay.apk`

**为什么这条路能走通**（详见 `os4/docs/overlay_双路径机制与可修改性.md`）：

| overlay | target | 生效路径 | 改 arsc |
|---|---|---|---|
| **DevicesAndroidOverlay.apk** | `android` | 开机 `idmap2 create-multiple`，**绕过 OMS 证书检查** | **可以** |
| DevicesOverlay.apk | `com.android.systemui` | OMS 静态 overlay，PMS 强制与 target 同证书 | 不行（改=静默失效） |

donor overlay 的值 vs 本机目标值：

| 资源 | donor（Redmi K 底包） | 本包（RMX5010） |
|---|---|---|
| `rounded_corner_radius{,_top,_bottom}` | 170 px | **116 px** |
| `status_bar_height_{default,portrait}` | 144 px | **160 px** |
| `config_mainBuiltInDisplayCutout` | （donor 的刘海） | `M 0,0 H -34.0 V 140 H 34.0 V 0 H 0 Z`（68×140 挖孔） |

换之前核对过资源键集合：候选包含 donor 的全部 23 个键（0 缺失），不会丢其它资源。

**没做的两项（仍需要 root + KSU bind-mount）**：`status_bar_padding_top=14px`、
`cut_out_center_y=75px`（灵动岛位置）——它们属于 `com.android.systemui` target 的静态 overlay，
证书锁死改不了（`DevicesOverlay.apk` 只能在开机扫描后用 mount --bind 盖上去）。

验证：

```bash
adb shell cmd overlay list --user 0 | grep -i devices        # 包在列表里且为 [x]
adb shell cmd overlay lookup --user 0 android android:dimen/rounded_corner_radius   # 116
adb shell cmd overlay lookup --user 0 android android:dimen/status_bar_height_portrait # 160
# 视觉：四角圆角与状态栏高度（截图对比刘海两侧留白）
```

## 刷写

```bat
fastboot reboot fastboot
fastboot -S 128M flash product_a images\product.img
fastboot reboot
```

不需要清数据。回滚：`_before_bright_overlay/images/product.img`。

## 2026-10-25 曲线溯源结论:本文件 ≡ 原厂 16.0.7.201 主曲线

将本载荷(11,871B)与 16.0.7.201 原厂 vendor 的 5 份 displayconfig 逐点对比:
- 4 份 7,366B 变体:52 点、nits 0.2289~782.428、HBM(0.85/500/1.5)——与本文件
  **数值逐点一致**(字节差异仅为注释/格式);
- 1 份 2,674B:3 点粗化曲线(2/500/800),备用面板变体 fallback,精度更差。

即本文件就是原厂曲线本体(经 OS3/nezha/haotian 三代实机验证),无需更换。
haotian 底屏幕 uniqueId 实测仍为 local:4630947008615494291(硬件/DRM 上报,跨 ROM 稳定)。
框架侧验证:dumpsys display 显示 mDdcAutoBrightnessAvailable=true、
mBrightnessLevelsLuxMap 39 级 lux(2~30000)已进 ABC。
