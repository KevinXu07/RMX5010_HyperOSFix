# 屏幕分辨率切换、120Hz 刷新率与原生内核级 LTPO 驱动（Resolution, Refresh Rate & Native LTPO Fix）

面向 **realme GT7 Pro（RMX5010）** 移植小米 HyperOS 的全套分辨率、高刷与自适应降频方案。
**全原生内置进 ROM（54 分区底包），100% 免 Root、免 Magisk、免 LSPosed 模块。**

---

## 症状与现象

1. **刷新率锁死 60Hz**：
   系统开机、日常使用与应用滑动全程固定在 60 FPS / 60 Hz，高刷特性未生效。
2. **分辨率选项缺失**：
   在系统「设置 -> 显示 -> 屏幕分辨率」中，没有 1.5K（1264×2780）与 1080p（1080×2376）两档分辨率切换选项。
3. **日常自适应降频失效**：
   即使框架开到了 120Hz，面板在空闲时也不会降频到 10Hz/1Hz 省电；或者在切应用后立刻被打回 60Hz。

---

## 根因剖析

### 1. 上层框架门禁（`nezha.xml` 与属性）
- nezha（红米底包）原厂为 2K 屏规格，其 `device_features/nezha.xml` 中**完全缺失** `<integer-array name="screen_resolution_supported">` 节点，导致系统框架（`DisplayModeDirector` 与 `MiuiSettings`）无法枚举出适用于 realme GT7 Pro（1.5K 定制屏）的分辨率档位。
- `nezha.xml` 原始配置中写死了全局默认帧率：
  ```xml
  <integer name="defaultFps">60</integer>
  ```
  在未手动干预或全新刷入时，系统默认给 `Settings.System.PEAK_REFRESH_RATE` 赋予 60.0，直接将帧率上限锁在 60Hz。
- 缺少 MIUI 专有的动态刷新率调度属性 `ro.vendor.display.dynamic_refresh_rate` 和 `persist.sys.miui_resolution`。

### 2. 底层内核驱动重置机制（为什么 OS3 方案 A 效果不好）
实机日志证明，Oplus 底层显示驱动（ColorOS 内核）会在以下日常场景频繁调用内核函数：
```text
[ADFR][0][INFO][oplus_adfr_status_reset:1804] sa status reset: auto_mode:0, sa_min_fps:60/120
```
- 打开应用、启动相机、切横屏、视频起播等，内核都会随时触发重置，把 ADFR 自适应重置为固定帧率。
- OS3 方案 A（仅挂在亮屏广播上的 userspace 脚本）在中途重置后无法感知，导致日常使用中频繁被打回 60Hz 或固定 120Hz，必须灭屏再亮屏才能恢复。

---

## 完整实施方案

### 一、上层框架门禁解封（`product.img`）

1. **`product/etc/device_features/nezha.xml`**：
   - 补齐分辨率数组：
     ```xml
     <integer-array name="screen_resolution_supported">
         <item>1264</item>
         <item>1080</item>
     </integer-array>
     ```
   - 解除 60Hz 默认封印：
     将 `<integer name="defaultFps">60</integer>` 修改为 `120`。
   - 补全画质增强与 AOD 帧率：
     ```xml
     <bool name="support_screen_enhance_engine">true</bool>
     <integer name="aon_screen_off_fps">0</integer>
     ```
2. **`product/etc/displayconfig/display_id_4630947008615494291.xml`**：
   - 彻底删除 500ms 提前触发 idle 显示状态的 `<idleScreenRefreshRateTimeout>` 代码块。
3. **`product/etc/build.prop`**：
   ```properties
   ro.vendor.display.dynamic_refresh_rate=120,60:100,60,5
   persist.sys.miui_resolution=1264,2780,500
   ```

### 二、底层内核驱动事件拦截（`vendor.img`，方案 B 原生内置）

参考一加 13（OP13）开源模块方案，采用 kprobe/kretprobe 拦截内核符号 `oplus_adfr_status_reset`：
- **内核源码基线**：对齐官方开源仓 [`realme_GT7pro-AndroidV-kernel-source`](https://github.com/realme-kernel-opensource/realme_GT7pro-AndroidV-kernel-source) 的 **`kernel-6.6.89`** 分支（Android 15 GKI Linux 6.6.89）。
- **内核驱动载荷**：[`kernel-src/rmx5010_ltpo_restore.c`](kernel-src/rmx5010_ltpo_restore.c)，二进制位于 `/vendor/bin/rmx5010_ltpo_restore.ko`。
  - `vermagic`: `6.6.89-android15-8-g7e1f3c083cc6-abogki467167594-4k SMP preempt mod_unload modversions aarch64`
  - 标签：`u:object_r:vendor_file:s0`
- **原生自启动规则**：`/vendor/etc/init/rmx5010_ltpo.rc`
  ```rc
  on property:sys.boot_completed=1
      insmod /vendor/bin/rmx5010_ltpo_restore.ko min_fps=10 delay_ms=350 apply_on_load=1
  ```
  - 标签：`u:object_r:vendor_configs_file:s0`
  - `vendor_init` 拥有原生 `module_load` 权限，开机由系统 PID 1 自动加载，零 AVC denial，完全免 Root。

---

## 产物哈希与验证

- `product.img` (sparse): `69b185a3322f1ec127c41804f5a85c66eff912d2269481c02e9fbcde40184a34`
- `vendor.img` (sparse): `ff855fbac9fb73ee85e77bbb5c41fce4a64f53e0694d5ce840615cad9068b4f8`
- `verify_package.ps1 -Strict` 54/54 全部分区哈希严格通过。

## 2026-10-25 补充(haotian 主线):框架门禁迁移完成

haotian OS4.0.0.19 底上迁移本项目(仅 product.img 层,LTPO 内核模块未迁移):
- device_features/haotian.xml(非 nezha.xml):defaultFps 60→120、
  screen_resolution_supported 1440,1080→**1264,1080**(本机 1.5K 屏宽 1264)、
  纸护眼门禁不动——15 Pro 底原生无变黄问题(该修复在 17U 底上实测无效,已废弃);
- product build.prop:+dynamic_refresh_rate +persist.sys.miui_resolution=1264,2780,500;
- 曲线文件删 idleScreenRefreshRateTimeout 块(本底 1 处)。
实机:defaultFps=120、supportedRefreshRates [120,60,40,30,24,20]、Enforcing ✅。
**待观察**:切应用/开相机时 ADFR 内核重置是否把 120Hz 打回 60——若发生,迁移
LTPO 模块(rmx5010_ltpo_restore.ko,需重建 vendor.img,haotian 底 vendor 管线已通)。

## 2026-10-25 补充(haotian 主线):LTPO 模块迁移完成,实机加载验证

- 交付:`rmx5010_ltpo_restore.ko` → `/vendor/bin/`(vendor_file)+
  `rmx5010_ltpo.rc` → `/vendor/etc/init/`(vendor_configs_file),vendor.img 重建刷入;
- 实机:`init: processing action (sys.boot_completed=1) from rmx5010_ltpo.rc:3` →
  insmod 成功,`op13_ltpo_restore: active, min_fps=10 delay_ms=350`(模块内名沿用
  op13 构建旧名),kretprobe 挂 oplus_adfr_status_reset,boot 早期即向面板发出
  `qcom,mdss-dsi-hpwm-adfr-min-fps-1-command`(ADFR 下限 10Hz 生效);
- 注意 1:rc 文件勿带 UTF-8 BOM(本次实测带 BOM 也能被 init 解析,但不应依赖);
- 注意 2:观测面板自浮**不要用** dynamic_osc_clock(cmd 模式位时钟恒定不变),
  应以 ADFR dmesg 命令序列 / 待机功耗为准;
- 注意 3:静置无浮动假象的另一来源——shell 视角 getprop/属性查询受 SELinux
  可见性限制(参见 nfc-nxp-fix 2026-10-25 终版更正)。
