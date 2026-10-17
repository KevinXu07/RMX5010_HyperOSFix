# 音频爆音 / 切音"哔"声修复（Audio Policy appname Standby Loop Fix）

面向 **realme GT7 Pro（RMX5010）** 移植小米 HyperOS 的音频爆音修复方案。

---

## 症状与现象

- 播放视频或音乐（如抖音、B站、网易云音乐等）切视频、切歌曲、进出后台时，扬声器/耳机频繁发出短促的**爆音 / "哔"声**。
- 日志特征（logcat）：
  ```text
  AudioFlinger: ... setParameters() failed with keyValuePair appname=+com.ss.android.ugc.aweme, entering standby
  AudioFlinger: ... setParameters() failed with keyValuePair appname=-com.ss.android.ugc.aweme, entering standby
  ```
  单次应用会话即可产生 20+ 次上述报错与 standby 重建。

---

## 根因分析

1. **MIUI 系统侧行为**：
   MIUI 的 `AudioPolicyManagerImpl`（位于 `/system_ext/lib64/libaudiopolicymanagerimpl.so`）在每条 `AudioTrack` 建立和销毁时，都会通过 `setAppNameParameter` 函数向当前活动的音频输出流推送特定的 vendor 参数：
   - 音轨创建：`appname=+包名`
   - 音轨销毁：`appname=-包名`
   此功能用于 MIUI 自带的游戏音频增强和动态音频用例跟踪。

2. **硬件侧冲突**：
   realme GT7 Pro 的高通音频 HAL 驱动（`/vendor/lib64/hw/libaudiocorehal.qti.so`）完全不支持 `appname` 这一非标准 vendor 参数，底层 `StreamHalAidl::parseAndSetVendorParameters` 拒绝并返回错误代码。

3. **连锁反应**：
   AudioFlinger 收到 `setParameters()` 失败后，执行防御性 fallback 逻辑：**强制整条输出流进入 standby 并销毁重建**。底层硬件 PAL 层功放（speaker amplifier）随即经历一次关断上电，产生物理上的爆音/破音。

---

## 修复方案

直接修补 `/system_ext/lib64/libaudiopolicymanagerimpl.so`，使 `setAppNameParameter` 变为无操作（No-op）直接返回。

### 汇编修改详情

函数入口位于偏移 `0x3d914`：
```asm
0x3d914: 5f 24 03 d5    BTI c           ; 保留 ARMv8.5-A 分支目标识别
0x3d918: 28 00 40 f9    LDR X8, [X1]    ; [原逻辑] 读取 TrackClientDescriptor 指针
```

补丁修改：
- **目标文件**：`/system_ext/lib64/libaudiopolicymanagerimpl.so`
- **补丁偏移**：`0x3d918`
- **原指令**：`28 00 40 f9` (`LDR X8, [X1]`)
- **新指令**：`c0 03 5f d6` (`RET`)

由于保留了 `0x3d914` 的 `BTI c`，所有通过 `BLR` 的间接跳转均不受 ARMv8.5-A BTI 安全机制阻断；紧接着执行 `RET` 立即返回 `void`，无额外寄存器或栈污染。

---

## 载荷与脚本

- 自动化修补脚本：[`scripts/patch_audiopolicy.py`](scripts/patch_audiopolicy.py)
- 应用于 `system_ext.img` 镜像重建，保持 EROFS 文件系统标签 `u:object_r:system_lib_file:s0`。

---

## 验证结论

- **镜像校验**：`mkfs.erofs -zlz4hc -C262144 -b4096 -T0` 重建 `system_ext.img`，`fsck.erofs` 校验通过，差分严格限制在 `libaudiopolicymanagerimpl.so` 单个文件。
- **运行效果**：`appname` 参数推送完全消除，AudioFlinger 输出流不再发生因参数失败导致的被迫 standby，功放断电上电循环彻底消除，切音/切歌完全静音平滑。
