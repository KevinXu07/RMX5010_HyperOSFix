# 屏幕色彩：HyperOS 设置桥接到 ColorOS 校准模式（2026-11-12）

## 问题
HyperOS 设置 → 显示 → 色彩风格里切模式或调色温，屏幕没有任何变化；色温只显示几个灰掉的按钮。

## 原因
- 小米链路：设置写 `screen_optimize_mode` / `screen_color_level`，system_server 里的
  `DisplayFeatureManagerService.setDisplayFeature(displayId, mode, value, cookie)` 再调用
  `vendor.xiaomi.hardware.displayfeature(_aidl)`。移植包用的是 ColorOS vendor，没有这个 HAL，
  服务找不到 wrapper 就直接丢弃（日志里只有 `initProxyLocked`）。
- 色温 UI 由 `ro.(vendor.)colorpick_adjust`（显示调色盘）和
  `ro.(vendor.)all_modes.colorpick_adjust`（所有模式可调）控制，小米 vendor 才有。

## ColorOS 原厂怎么做（stock 201 `oplus-services.jar`，`OplusFeatureColorMode.updateColorMode1`）
- 高通平台：每个模式 = 一个厂商 render intent，`ColorDisplayService.setColorModeExt(intent)`
  → SurfaceFlinger 1023（setDisplayColorSetting）→ 高通 composer 里的出厂 QDCM 校准；另发私有码
  `0x5a4a`/`0x5a47` 给 ColorOS 自己的 SF（HyperOS SF 不认，不需要）。
- 本机 `oplus.software.display.wcg_2.0_support`：标准 301、自然 303、鲜艳 307。
- composer 支持的 intent（`dumpsys SurfaceFlinger` “Color Modes”）：
  sRGB(7) 260–263/265/300/301/303/307；P3(9) 256–259/264/302/304/308–310。
  HyperOS SF 实测能应用 sRGB 组；P3 组会退回 NATIVE（它不会为 sRGB 内容切 P3）。

## 桥接实现
Sense `ScreenColorBridgeHooks`（system_server，Sense 1.47 起）：

| 小米设置 | setFeature mode | 处理 |
|---|---|---|
| 生动（screen_optimize_mode 1） | 0 | intent 303 + 色温 |
| 鲜艳（2） | 1 | intent 307 + 色温 |
| 专业原色（3） | 2 | intent 301 + 色温 |
| 色温（调色盘模式） | 23 | 色彩矩阵 level 126 |
| 阅读/护眼 | 3 | 色彩矩阵 level 101（未实测） |
| 高级模式 | 26 | 见下节（Sense 1.48 起） |
| 原彩 32 等 | — | 未桥接，只记日志 |

### 高级模式（mode 26）
`setFeature(26, value, cookie)`，cookie 为参数编号（`ExpertData.Cookie`），完整参数存于
`Settings.System expert_data`（JSON）。范围取自 haotian `device_features`：

| cookie | 参数 | 范围/默认 | 实现 |
|---|---|---|---|
| 0 | 色域 | 0–3 / 0 | 切 intent：0→307，1→301，2→303，3→301（2、3 的界面名称未核对） |
| 1–3 | R/G/B | 50–255 / 255 | 增益 v/255 |
| 4 | 色相 | ±180 / 0 | 绕亮度轴旋转 |
| 5 | 饱和度 | ±50 / 0 | 0.5–1.5 倍 |
| 6 | 明度 | ±255 / 0 | 0.7–1.3 倍（`need_remove_expert_bright`，界面通常隐藏） |
| 7 | 对比度 | ±100 / 0 | 以中灰为中心 0.5–1.5 倍 |
| 8 | 伽马 | 170–270 / 220 | **不支持**（非线性，色彩矩阵做不了） |
| 9 / 10 | 恢复默认 / 应用 expert_data | — | 重置参数 / 读取 JSON |

R/G/B、色相、饱和度、明度、对比度合成一个仿射矩阵，放在 level 127；进入高级模式清掉色温矩阵，
切回生动/鲜艳/专业原色时清掉高级模式矩阵。

- intent 通过 `DisplayTransformManager.setDisplayColor(intent, -1)` 下发，会写
  `persist.sys.sf.native_mode`，SF 开机即沿用；同时 hook `DisplayTransformManager.setColorMode`，
  防止 ColorDisplayService 开机/切用户时把它改回 0。
- 色温值：1 暖 / 2 自然 / 3 冷；调色盘存的是 `ScreenColorAlgorithm.encode(像素)` 的 ARGB，
  按颜色比例换算 RGB 增益（实测 0.90～1.00）。
- 模块 1.7.9 `post-fs-data.sh` 开机设 `ro.colorpick_adjust=true`、`ro.all_modes.colorpick_adjust=true`。

## 已验证（1.7.9 前的软重启测试）
三种模式切换 HWC intent 分别为 303/307/301；调色盘在三种模式下可用，色温变化可见。

高级模式（Sense 1.48，2026-11-12 实测）：色域 0/1 分别切到 307/301，饱和度/明度/对比度拖动后矩阵随之更新，
退出高级模式后恢复专业原色 301。

## 未做
伽马、智能色温调节（需环境色温传感器）、P3 组 intent；色域选项 2/3 未实测。
