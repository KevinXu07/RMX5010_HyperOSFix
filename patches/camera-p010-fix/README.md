# 相机 P010 厂商格式越界崩溃修复（Camera P010 Native Buffer Overflow Fix）

面向 **realme GT7 Pro（RMX5010）** 移植小米 HyperOS 的相机拍照底层格式修复方案。

---

## 症状与现象

- 在使用 Realme 原厂相机或三方高规格拍照（10-bit HDR / RAW10 照片流）拍摄时，相机底层服务或算法库发生 `SIGSEGV`（段错误闪退）。
- 典型报错崩溃堆栈（tombstones / logcat）：
  ```text
  signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x...
  backtrace:
      #00 pc 000000000003b128  /odm/lib64/libaps_wrapper.so (APSFormatConverterNeon::p010LSB2MSBNeon+120)
  ```
- 现象：快门按下后未生成照片，或预览画面直接卡死并导致相机进程被系统杀死。

---

## 根因分析

1. **realme 专有像素格式**：
   realme GT7 Pro 的高通相机底层 HAL 驱动在输出 10-bit RAW/YCbCr 缓冲时，使用厂商扩展格式代号 **`0x7fa30c0a`**。
2. **小米 `libnativewindow.so` 格式分发缺失**：
   小米原厂 `/system/lib64/libnativewindow.so` 的 `lockAsyncYCbCr` 函数中，硬编码识别的标准格式仅包含标准 YV12、NV21、Y16 等，根本没有针对 `0x7fa30c0a` 的步长计算与 stride 解析分支。
3. **内存越界**：
   由于返回了无效或未对齐的步长信息，后续算法库 `APSFormatConverterNeon::p010LSB2MSBNeon` 在做 36MiB `AHardwareBuffer` 格式转换时计算出错误的跨距地址，直接读写到了非映射页，引发 SIGSEGV 崩溃。

---

## 修复实施

### 二进制补丁方案

对 `/system/lib64/libnativewindow.so` 进行无损注入：
- **原理**：保留全部原有格式分支（包括 Y16 和标准 YCbCr），在可执行段末尾的代码空洞（code cave 偏移 `0xac78`）写入一条蹦床（trampoline）。
- **新增分支逻辑**：
  ```asm
  0xac78: 48 81 81 52    movz w8, #0x0c0a
  0xac7c: 68 f4 af 72    movk w8, #0x7fa3, lsl #16  ; w8 = 0x7fa30c0a
  0xac80: bf 02 08 6b    cmp  w21, w8              ; 比较格式是否为 0x7fa30c0a
  0xac84: 40 e0 fe 54    b.eq 0x888c               ; 命中则跳入原厂既有的 YCbCr 步长解析路径
  ; 未命中则恢复原始 Y16 分支：
  0xac88: 28 2b 86 52    movz w8, #0x3159
  0xac8c: c8 06 a4 72    movk w8, #0x2036, lsl #16
  0xac90: 14 f7 ff 17    b    0x88e0
  ```
- **挂钩入口**：在原偏移 `0x88d8` 将原指令替换为直接跳转至 `0xac78` 的 `b` 指令与 `nop`。
- **段表适配**：将该 ELF 库的可执行段大小安全扩展 28 字节，位于已有 mapped 4KB 页面内，完全避免重定位或符号污染。

---

## 验证与产物

- **自动化脚本**：[`scripts/patch_nativewindow_p010_v2.py`](scripts/patch_nativewindow_p010_v2.py)
- **输入 SHA-256**：`49320d4379fa926acf72fab24fd0f883285622aa160086c8f705de56a44ed77d`（小米 nezha 原厂）
- **输出 SHA-256**：`1dc76b92d7bdfdf9162841f6b51feb0d7b21b692be3b4297411fbc4698faf9d3`
- **镜像结果**：`system.img` (sparse SHA-256: `54a561512b991cfe6c75f84db2d84445ec4261cde14e66a9e19216ea624d4066`)。
- **测试效果**：快门拍照流程中 `APSFormatConverterNeon::p010LSB2MSBNeon` 越界崩溃彻底消除，10-bit HDR 与 RAW10 拍照正常落盘。
