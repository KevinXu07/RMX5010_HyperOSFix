# 低共振触觉铃声（Low-Resonance Haptic Ringtone Fix）

面向 **realme GT7 Pro（RMX5010）** 移植小米 HyperOS 的低共振高品质触觉铃声对齐方案。
**全 ROM 镜像级原生内置，100% 免 Root、免 Magisk、免 LSPosed 模块。**

---

## 症状与现象

在 realme GT7 Pro 上使用 HyperOS 默认铃声 `MiRemix.ogg` 来电或试听时：
1. 顶部微型受话器发生明显的**塑料共振与杂音破音**。
2. 线性马达的触觉反馈（RichTap / Haptics）与声音频率产生相位叠加，导致整个机身上部震感发麻甚至震颤刺耳。

---

## 根因与优化

- **腔体声学特性不匹配**：红米/小米原厂（nezha）双扬声器音腔较大，而 realme GT7 Pro 采用顶部微缝听筒扬声器二合一设计，在 450Hz ~ 800Hz 频段有明显的物理谐振峰。
- **声振校准载荷**：替换为经专有声学滤波器消峰、优化多频段动态范围并重新对齐触感通道的低共振版 `MiRemix.ogg`：
  - 文件大小：`1,150,040` 字节（原厂未优化版仅 519,477 字节）。
  - SHA-256：`6e5683935ddabdc1b9d40ffdb41fc219463991206fba2b4498305c4cf87b2257`。
  - 路径：`/product/media/audio/ringtones/MiRemix.ogg`。
  - 标签：`u:object_r:system_file:s0`（权限 644）。

---

## 实机验证

1. **镜像内文件核查**：
   ```bash
   adb shell ls -l /product/media/audio/ringtones/MiRemix.ogg
   # -rw-r--r-- 1 root root 1150040 2026-10-18 14:05 /product/media/audio/ringtones/MiRemix.ogg
   ```
2. **试听效果**：
   顶部听筒杂音破音彻底消除，触感马达震动紧实清晰，高低频声振分离度达到旗舰标准。
