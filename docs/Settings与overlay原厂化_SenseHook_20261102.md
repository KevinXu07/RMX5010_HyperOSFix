# Settings/overlay 原厂化 + Sense LSPosed hook（2026-11-02）

## 背景

整包 `fastboot -w` 后出现两个问题：Settings 消失、灵动岛回到默认位置。

根因是镜像里的 APK 被改过但签名摘要失效：

- `system_ext` 的 `Settings.apk`：`sharedUserId="android.uid.system"`，APK v3
  签名校验失败。数据还在时 PMS 不重扫，所以一直能用；`-w` 后首次扫描验签
  失败，PMS 直接跳过该包 → 设置消失。
- `product/overlay/DevicesOverlay.apk` 签名摘要不匹配；
  `DevicesAndroidOverlay.apk` 的签名块被剥离。Android 17 对第三方签名的
  overlay 要求同证书或 `android:targetName`，SystemUI 没有声明 overlayable
  组，因此第三方 RRO 也装不上 → 灵动岛回默认（93.634px / padding 0）。

实测“完全不签名”也无效：PMS 在 Android 17 user 构建上会拒绝无签名/坏签名
的预置 APK，`sharedUserId` 更强制要求平台证书。

另外，对比设备改版 Settings 与 stage 原厂签名版：`classes3.dex` 里 9 个类
不同，其中 8 个只是 `static boolean = false` 的静态初值元数据差异；真正的
补丁只有 `MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment` 给
0 号进度视图补 `$15` 监听器（人脸录入卡进度环修复）。

## 原厂化改动

### system_ext

- 用 `stage_h19/system_ext/priv-app/Settings/Settings.apk`（原厂签名，
  MIUI 平台证书验签通过）替换回读 system_ext 中的改版 Settings。
- 从回读 system_ext 提取真实 SELinux 标签生成 file_contexts，EROFS 用
  `-zlz4 -E legacy-compress -b4096 -T0 --mount-point=/` 重建。
- 标签逐条比对：0 处不匹配。
- `images/system_ext.img` SHA-256 `08c0e1634fdbfd0b2fa08d7cf35fb7ab59352ddefee1eecb5ec6ce80803503d6`。

### product

- 从 haotian donor payload 提取原版 product，取出：
  - `overlay/DevicesOverlay.apk` SHA-256 `ffa39eb9…`（23,724,638 B）
  - `overlay/DevicesAndroidOverlay.apk` SHA-256 `bd60256e…`（16,892 B）
  - 两者均用 MIUI 平台证书验签通过。
- 以回读 product（相机终版 `27108e…`，含 OplusCamera）为底，只替换上述两个
  overlay，EROFS 同样用 legacy-compress + 回读标签 contexts 重建。
- 标签 0 不匹配；两张 overlay 哈希与 donor 原版一致。
- `images/product.img` SHA-256 `b1c8b190c44edfe553f4faa0364b52a865e1e1763f5c57e0193ec5ac9070e81b`。

### vbmeta

三件套保持 flags=3（`a32f25f5…` / `2cad200c…` / `773c1b4f…`），不依赖
fastboot 的 `--disable-verity` 后缀。

## Sense LSPosed hook

新增两个 hook，编入现有 Sense（package `com.zephiel.sense`）：

- `FaceEnrollHooks`（Settings 进程）：hook
  `NewMultiFaceEnrollFragment.initProgressView()` 之后，读取
  `mFaceInputProgressViews` 列表第 0 项，反射构造
  `NewMultiFaceEnrollFragment$15(fragment)` 并调用
  `addAnimatorListener`，补回缺失的动画结束回调。
- `IslandHooks`（SystemUI 进程）：hook
  `android.content.res.Resources` 的 `getDimensionPixelSize` /
  `getDimensionPixelOffset` / `getDimension`：
  - `0x7f0702c1`（`cut_out_center_y`）→ 74
  - `0x7f071938`（`status_bar_padding_top`）→ 14

构建：`scripts/build_sense_module.sh` → `out/Sense-RMX5010.apk`，
SHA-256 `c44aad1a8da6673a9193737435bd8db7995caa8b9a0ce16457b46ad4d184a039`。
包内副本：`camera_fix/Sense-RMX5010-hooks.apk`。

LSPosed 作用域需包含 `com.android.settings` 与 `com.android.systemui`
（以及相机、钱包等原有作用域）。

## 刷写

2026-11-02 16:05 完成整包清数据刷入：

1. bootloader：官方 vbmeta 三件套（进入 fastbootd 用）→ stock
   boot/vendor_boot/dtbo/recovery + SukiSU init_boot
2. `fastboot -w`：userdata 224GB、metadata 64MB 重建
3. fastbootd：15 个动态分区（`-S 128M`，my_* 先、product 最后）
4. 预置 flags=3 的 vbmeta 三件套
5. 重启，无回流 fastboot

## 注意

- 分享包 zip 尚未重建（images 已变化），待实机回归后再打包。
- LSPosed 框架未随包提供；未启用 Sense 时灵动岛为 donor 默认位置，
  人脸录入仍可能卡在进度环。
