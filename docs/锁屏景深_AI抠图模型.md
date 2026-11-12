# 锁屏景深：AI 抠图模型未注册（2026-11-12）

## 问题
锁屏样式（`com.miui.aod:keyguardeditor`）里“景深”按钮一直是灰的；同一张壁纸在小米真机上能开。

## 排查链路
1. 按钮状态由 `EffectsTemplateView.processHierarchy` 决定：壁纸记录 `supportSubject=true`
   或类型为 `gallery` 时才去抠图，否则直接 `updateHierarchyButton: DISABLE`。
   设备等级（`DeviceUtil.isLiteDevice`）判断正常通过，不是机型限制。
2. 在编辑器里经“壁纸 → 相册”重选后抠图真正执行，但返回空：
   ```
   Taiyi-Service AIConfigurations: getAIConfig segment:: -> []
   Taiyi-Sdk-AIManager: loadSync AIDetail(segment, null, {}, false, 0) not support!
   Taiyi-Sdk-AIAbility(segment): segment response code: 10600
   ImageSegmentHandler: end segment segmentResult?.bitmap: null
   ```
3. 抠图由 AIService（`com.xiaomi.aiservice`，Taiyi 框架）提供。它的预装插件/模型/配置
   只从写死的 `/mi_ext/product/ai/taiyi` 读取（`w1/f.a()`/`c()`，路径常量 `v1/c.z`）。
   移植包把这些文件放在 `/product/ai/taiyi`，`/mi_ext` 是空目录，于是
   `segment_v3_npu` 插件、`segment_model_qcom_qnn` 模型、`segment_qcom_qnn_8750.json`
   配置从未注册（`ai_db` 的 `ai_config`/`local_resource` 里没有）。
   OCR、宠物识别等能用，是因为它们走云端下载；抠图只有预装版本。

## 修复
模块 `post-fs-data.sh`：在 init 挂载命名空间里给 `/mi_ext` 挂一个只读 tmpfs，
再把 `/product/ai/taiyi`、`/product/etc/cust_features` bind 到 `/mi_ext/product/` 下对应路径，
并建空目录 `/mi_ext/product/opcust`（1.7.12 起，见下节普查）。`/mi_ext/product` 已存在时跳过。

AIService 只在 OTA 版本变化时导入预装资源（`AIConfigCache: sync by ota changed`，
比较 `shared_prefs/common.xml` 里 `initialize_record.otaVersion` 与当前版本）：
- 清 data 后首次启动：挂载已在 post-fs-data 完成，会自动导入。
- 已初始化过的机器：需要触发一次重新导入——停掉 AIService，把 `common.xml` 里
  `initialize_record` 的 `otaVersion` 改成别的值，再启动它（例如打开
  `am start -a com.xiaomi.aiservice.MODEL_LOCAL`）。导入完成后它会写回真实版本号。

## mi_ext 路径普查（2026-11-12）
donor（haotian OS4.0.0.19）`mi_ext` 分区共 81 个文件（从 payload 重新提取核对）；`mi_product`
只有一行 `ro.mi.version.mi_product=empty`。构建时 mi_ext 内容已合并进 product/system/system_ext：
78 个载荷文件在实机对应路径全部存在，`mi_ext/etc/build.prop` 的属性实机全部一致。

扫描实机全部 apk/jar/so/bin/rc 中硬编码的 `/mi_ext`、`/mnt/vendor/mi_ext` 路径，
只有引用 donor mi_ext 里**真实存在**的内容才会和原机行为不同：

| 读取方 | 路径 | donor mi_ext 有 | 结论 |
|---|---|---|---|
| AIService | `product/ai/taiyi` | 有 | **缺失 → 已修**（景深/视频抠图/ner） |
| miui-services `CustFeatureResolveHelper`、`libskuparser_ffi` | `product/etc/cust_features`、`product/opcust` | 有 | **缺失 → 已修**（约 70 项机型/地区/SIM 特性全部读成默认值） |
| Settings | `etc/NOTICE.xml.gz` | 有 | 仅“法律信息”里少一段开源许可，未处理 |
| miui-framework、SystemUIPlugin、MiLink、XMNfcNci 等 | `product/etc/device_features` | 无 | 原机同样回落 `/product`，无影响 |
| PreinstallApp / OperatorPreinstall | `product/etc/pre_install.appsflyer`、`operator_product_data_app.list` | 无 | 无影响；不能整盘 bind `/product`，否则会暴露这类文件 |
| miui-telephony-common、CarrierConfig | `eccdata`、`vendor_device.xml` | 无 | 无影响 |
| init/fs_mgr/vold/update_engine/snapshot | `/mnt/vendor/mi_ext/...` | — | 分区挂载/OTA 与 build.prop/rc 加载；属性已合并，rc 中的 usr/precust_theme overlay 已由合并替代；`init.miui.ext.rc` 的 xbin/remount 仅 debuggable 生效 |

cust_features 修复前后用 `service call HyperOSCustFeatureResolve 2 s16 <key> i32 0` 实测：
`persist.vendor.bluetooth.lhdc_v5.supported`、`support_bt_dbam`、`support_audio_share_ui`、
`config_greezer_dfs_enable`、`support_cellbroadcast_cn`、`config_disable_cnap` 由 0 变为 1。

## 验证（2026-11-12）
重新导入日志出现 `readResourceFromFile PLUGIN segment_v3_npu 3`、
`MODEL segment_model_qcom_qnn 1`、`readConfigsFromConfigDir segment_qcom_qnn_8750.json`；
在锁屏样式里经相册重选壁纸后，景深按钮可用，效果正常。
同时补上了 `video_segment_qcom`（视频壁纸景深）和 `ner` 的注册。
