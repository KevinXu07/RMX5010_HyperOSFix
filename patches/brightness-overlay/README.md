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

## 2026-10-25 补充(haotian 主线):几何迁移完成

h19 底(0.19 donor)的 DevicesAndroidOverlay.apk 为 haotian 自带(16,892B,
圆角 140/挖孔 81×169/状态栏高度 donor 值),已换回本验证版(10,911B)。
实机:roundedCorners radius=116 ✓、cutoutSpec M 0,0 H -34.0 V 140 H 34.0 V 0 H 0 Z
(68×140)✓、Enforcing 开机正常。产品镜像为 haotian_work/product_geom.img。
未迁移:DevicesOverlay.apk(SystemUI target)的 status_bar_padding_top/bottom
与灵动岛位移——证书锁死,需 SukiSU bind-mount 模块 + 手机端 MT管理器改 arsc
(方案见 os4/docs/overlay_双路径机制与可修改性.md),待用户需要再做。

## 2026-10-25 补充(haotian 主线):灵动岛/状态栏 padding 固化完成(免模块)

h19 自带 DevicesOverlay.apk(SystemUI target,23.7MB)的 resources.arsc 做
字节级原位补丁(13 处 dimension,零长度变化):
- cut_out_center_y ×5 配置 → 72px(0x4800,12.25 用户确认位置)
- status_bar_padding_top ×5 配置 → 14px(0x0E00,12.22 实际命中值)
- dynamic_island_radius/expanded_shadow_radius/expanded_shadow_offset_y
  → OS3 原始 dp 编码(28.672974/57.345978/19.11499,取自 DevicesOverlay-os3.apk)
签名块原样拼回(不要重签):预置扫描容忍摘要失效(TeleService 先例),
OMS 证书匹配看签名块内证书(原证书=匹配保持)。
实机回读:cmd overlay lookup 三项全部命中(72px/14px/28.672974dip)✅。
补丁脚本:haotian_work/build_island.py(arsc 解析/定位/补丁/重打包/拼块一体)。

### 2026-10-25 微调:灵动岛 72→74px(用户实测后要求下移 2px)

build_island.py 的 cut_out_center_y 常数 0x4800(72px)→0x4A00(74px),
radix0 编码下常数即 px 值(72=0x4800/74=0x4A00/70=0x4600,每 2px 一档)。
重建刷入,实机 overlay lookup 回读 74.0px ✅。签名说明:全程不签名,
仅原样拼回原 APK 签名块(SystemUI target 的 OMS 证书匹配需要);
System APK 本体(非 overlay)完全无需签名块。

## 载荷(haotian 主线 74px 终版)

[DevicesOverlay-haotian-74px.apk](DevicesOverlay-haotian-74px.apk)(23,723,140B,
SHA-256 前缀 c664aa1f—74px 版本)——可直接放入 product/overlay/ 替换同名文件,
或用 [scripts/build_island_arsc_patch.py](../../scripts/build_island_arsc_patch.py)
从任意 haotian 底的 DevicesOverlay.apk 重新生成(常数 0x4A00=74px 可调)。
配套脚本:build_h19_autobrightness.sh(自动亮度)、build_h19_refresh.sh(刷新率)、
build_h19_vendor_nfc.sh(NFC vendor 闭包)。

## 2026-11-13 修正:亮度→尼特表按面板实测重建(自动亮度偏暗)

**现象**:自动亮度比 ColorOS 原厂暗,日常照度下约为原厂一半。

**根因**:上面"本文件 ≡ 原厂主曲线"的结论只对了一半——vendor displayconfig 是原厂
AOSP 路径的文件,ColorOS 自己并不用它算亮度:
- ColorOS 用 `display_brightness_config_common.xml` 的 lux_table 44(lux→尼特)+
  `display_brightness_config_P_1.xml`(level 0~10239→尼特),HWC 里的 Apollo
  (`libsdmcore` `ApolloService`,读 `/my_product/vendor/etc/display_apollo_list_AB849_P_1_A0022_dsc_cmd_mode_panel.xml`)
  再把 level 换成 DBV。Apollo 表每行 = level、DBV、实测尼特,即本面板的真实 DBV→尼特。
- HyperOS 没有 `/my_product`,Apollo 不工作,HWC 直接 DBV = 亮度×4093+1(实测 0.0963→395)。
- vendor displayconfig 的 `screenBrightnessMap` 与这块屏不符:0.098 标 27.5 尼特,实际 DBV 401
  只有 11.6 尼特;1.0 标 782,实际 2160。
- HyperOS 真正算自动亮度的是 refactor 策略(`RefactorAutoBrightnessAnimator`):lux→逻辑尼特
  (锚点 0/3.5、30/135、600/220、5000/1060)→实际尼特→**用 screenBrightnessMap 反查亮度值**。
  日志:17.47 lux → 逻辑 79.8 → 实际 49.47 尼特 → 0.1373;按面板实测 0.1373 只有 22 尼特。
  小米这条尼特目标本身与原厂 lux_table 44 很接近,错的只是尼特→亮度这张表。
  (displayconfig 里的 luxToBrightnessMapping 在 refactor 策略下不直接决定亮度。)

**修法**:`scripts/gen_brightness_map.py` 用 Apollo 表重建两处:
- `screenBrightnessMap`:139 点,value=(DBV−1)/4093 → 实测尼特(0→0.2289,1.0→2134.5);
- `luxToBrightnessMapping`:每个 lux 点取实际尼特等于 lux_table 44 目标的亮度值。
HBM transitionPoint 0.85 不动(手动最大物理亮度不变,约 1140 尼特)。
底稿用设备上的版本(已按刷新率补丁删掉 idleScreenRefreshRateTimeout)。

**载体**:KSU 模块 `overlay/display_id_4630947008615494291.xml`,post-fs-data
`overlay_mount` 绑到 `/product/etc/displayconfig/`(早于 system_server)。镜像里的旧文件不动。

**验证(2026-11-13)**:重启后 `dumpsys display` mNits 为新表;18.7 lux → 0.2085 → DBV 854 →
52.5 尼特(原厂目标 53;修正前同照度 0.146 → 24.5 尼特)。
息屏(AOD)同样走尼特表:~17 lux 时 0.0573/DBV 236/4.9 尼特 → 0.0994/DBV 408/12 尼特
(HyperOS 目标约 11 尼特),用户目视确认正常。高照度待实际使用确认。
