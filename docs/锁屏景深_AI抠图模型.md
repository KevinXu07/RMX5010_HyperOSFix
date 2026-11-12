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
再把 `/product/ai/taiyi` bind 到 `/mi_ext/product/ai/taiyi`。已存在该路径时跳过。

AIService 只在 OTA 版本变化时导入预装资源（`AIConfigCache: sync by ota changed`，
比较 `shared_prefs/common.xml` 里 `initialize_record.otaVersion` 与当前版本）：
- 清 data 后首次启动：挂载已在 post-fs-data 完成，会自动导入。
- 已初始化过的机器：需要触发一次重新导入——停掉 AIService，把 `common.xml` 里
  `initialize_record` 的 `otaVersion` 改成别的值，再启动它（例如打开
  `am start -a com.xiaomi.aiservice.MODEL_LOCAL`）。导入完成后它会写回真实版本号。

## 验证（2026-11-12）
重新导入日志出现 `readResourceFromFile PLUGIN segment_v3_npu 3`、
`MODEL segment_model_qcom_qnn 1`、`readConfigsFromConfigDir segment_qcom_qnn_8750.json`；
在锁屏样式里经相册重选壁纸后，景深按钮可用，效果正常。
同时补上了 `video_segment_qcom`（视频壁纸景深）和 `ner` 的注册。
