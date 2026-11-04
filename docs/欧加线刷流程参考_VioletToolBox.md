# 欧加线刷流程参考：VioletToolBox（2026-11-04）

## 来源

- 上游：<https://github.com/Smart-Paocai/VioletToolBox>，GPL-3.0
- 本地只读副本：`_refs/VioletToolBox`（不入库，不运行）
- 相关文件：`VioletToolBox/oujiaflash.cs`（约 1.14 万行）、`MainWindow.EdlFlash.cs`

本项目只参考其线刷流程设计，没有复制 C# 代码；我们的实现是
`out/full_image_haotian/flash_os4_rmx5010_haotian_54part.bat` +
`flash_device_check.ps1`。

## 普通线刷（`ExecuteNormalOujiaFlashWorkflowAsync`）

1. `PrepareOugaFastbootdDeviceAsync`：单设备、连接稳定性、解锁状态、
   A/B 槽位、当前是否 fastbootd。
2. `ValidateOujiaPartitionTableCompatibility`：把刷写包里的非逻辑分区
   逐个对照设备 `getvar all` 的分区表，不匹配直接终止（写之前）。
3. `PrepareOujiaCowPartitionsAsync` → `DeleteCowPartitions`：
   从 `getvar all` 里找出所有名字含 `cow` 的分区，逐个
   `delete-logical-partition`。虚拟 A/B 的快照分区会占用 super 空间，
   不清理时大镜像扩容会失败。
4. 每张镜像先解析**真实目标名**（`base_a` / `base_b` / 无槽分区），
   再 `flash <target> <img>`；逐分区执行、失败即停，最后汇总每个分区结果。
5. 高通设备把 `modem` 留到最后：先刷完 fastbootd 分区，重启回 bootloader，
   再把 modem 镜像按 A/B 两半分别写入（`slotABytes = len/2`）。
6. 收尾 `ExecuteOujiaPostFlashActionsAsync`：
   **FRP 必须在 fastbootd 擦除**；清数据用 `-w`，失败回退
   `erase userdata` + `erase metadata`；最后可选自动重启。

## 强力线刷（`ExecuteForceOujiaFlashWorkflowAsync`）

- 固定 A 槽：当前在 B 时，先把 A 的非逻辑分区（不含 modem）全部写一遍，
  再把活动槽切到 A；任何一步失败就保留 B 活动并终止，避免把设备刷成两槽都坏。
- `ExecutePowerFlashProcess` = “修复 super”：
  1. `set_active a`；
  2. `DeleteLogicalPartitionsForBothSlots`：删除**两个槽位**的全部逻辑分区；
  3. `CreateLogicalPartitionTargets`：`create-logical-partition <name>_<slot> 40`
     —— 40 MB 只是占位，真正容量靠 `fastboot flash` 时的自动扩容；
  4. 之后按普通流程刷逻辑分区、附加镜像、延迟 modem、收尾。
- 关键点：它**假定 fastboot 刷写逻辑分区时会自动扩容**，所以用占位尺寸重建。
  这解释了为什么普通刷写报 `Not enough space to resize partition` 时，
  删掉 COW 或重建逻辑分区就能继续。

## 我们采纳的

| 参考做法 | 我们的实现 |
|---|---|
| 设备预检（解锁/槽位/分区表） | `flash_device_check.ps1 -Stage bootloader`：product、current-slot、unlocked（明确未解锁直接停），8 个启动分区存在性（`getvar all` + `partition-type`/`has-slot` 兜底） |
| 写入前核对分区表 | `-Stage fastbootd`：15 个动态分区按当前槽位解析真实名字（`system` → `system_a`），缺失即停 |
| 镜像与分区尺寸核对 | 逐分区比较镜像文件大小与 `partition-size:`；小于镜像时提示自动扩容；镜像缺失直接停 |
| COW 快照清理 | `-CleanCow`：删除 `cow*` 逻辑分区后再刷 |
| 失败即停、最后汇总 | 批处理 `|| goto :err`；错误页提示“已写分区不回滚、可重跑” |
| `-w` 失败回退 | `-w` 失败后 `erase userdata` + `erase metadata`，两者都失败才停 |
| fastbootd 擦 FRP | 动态分区刷完、收尾 vbmeta 之前 `erase frp`（失败忽略） |
| 镜像由小到大刷写 | 未照搬：保留既有顺序（`my_*` 优先、大 `product` 最后），这是本机验证过的 super 空间顺序 |
| 强力模式的 super 修复 | `force` 参数：`set_active a` → 清 COW → 只对**缺失或小于镜像**的分区执行 delete + create（容量取原分区与镜像的较大值，向上取整到 MB）→ 普通流程刷写 |

## 我们没有照搬的

- **删除两个槽位的全部逻辑分区**：本机 `super` 里同时存在 `my_*` 和
  `my_*_a` 两套名字（`_a` 才是挂载的那套），整表重建会让 fastboot 的
  `has-slot` 解析和实际布局都变复杂；改为只修有问题的分区。
- **B → A 迁移**：本机逻辑分区只有 `_a`（lpdump 里没有任何 `_b`），
  没有可迁移的另一套，普通刷写只要求当前槽位是 A。
- **modem 延迟刷写**：本包不刷 `xbl/modem/tz/...` 等固件分区。
- **40 MB 占位重建**：我们优先用 `getvar all` 记录的原分区尺寸，
  只有分区完全缺失时才按镜像大小取整创建。
- 它的 GUI/进度/日志框架（C# WPF）与我们的批处理 + PowerShell 不同，
  没有引入。

## 实测（2026-11-04）

设备 RMX5010，`adb reboot bootloader` 后：

```
[设备] product = sun            # 这台的 bootloader product 是平台名，不是 RMX5010
[设备] 当前槽位 = a
[设备] 解锁状态 = yes
[分区表] bootloader 阶段目标分区齐全（8 个）
```

`fastboot reboot fastboot` 后：

```
[设备] fastbootd，当前槽位 = a
[分区] my_engineering.img -> my_engineering_a  镜像 328.0 KB  分区 328.0 KB
...（15 个全部分辨为 *_a，镜像与分区尺寸逐字节一致）
[分区表] fastbootd 阶段目标分区齐全（15 个），镜像大小校验通过
```

异常路径：临时造一个设备上不存在的分区名 → 退出码 1，提示
“普通刷写无法继续，可用 force 参数重跑本脚本重建 super 逻辑分区”。

**未实测**：`force` 真正执行 delete/create 的分支（会改 super 布局，
不在健康设备上演练），以及 COW 实际删除（本机当前没有 cow 分区）。

## 注意

- 清理 COW 会取消未完成的虚拟 A/B 快照。正常整包刷写前无所谓；
  如果设备上刚推送了 OTA 还没重启，别用本脚本。
- `force` 创建的逻辑分区容量向上取整到 MB，与出厂布局可能有几 MB 偏差；
  只在普通刷写失败时用。
