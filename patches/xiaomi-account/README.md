# patches/xiaomi-account — 小米账号 / MTD 依赖闭包

一个**独立可应用**的补丁：给 RMX5010（realme GT7 Pro，硬件底 ColorOS 16.0.7.201）的
`odm` 与 `vendor` 分区补上小米账号所需的 native HAL 闭包。

## 目录

```
payload/odm/          23 个文件（5 可执行 + 5 rc + 5 vintf manifest + 8 库）
payload/vendor/       29 个文件（原包全量；其中 11 个目标已有 → 应用时跳过）
vintf/                1 个本仓库补充的 manifest（blackbox，原包缺失、运行时必需）
selinux/mtd_block.cil                 mtd native 域闭包（112 行）
selinux/misys_hypys_block.cil         misys/hypsys/misyscore 域闭包（86 行）
selinux/odm_file_contexts             新建到 /odm/etc/selinux/（23 条）
selinux/vendor_service_contexts.append   追加 5 条 AIDL 服务名
selinux/vendor_property_contexts.append  追加 34 条属性
selinux/vendor_file_contexts.append      追加 21 条路径（含两条 /data、/mnt 目录映射）
labels.tsv            应用后每个路径的期望标签 + 跳过清单（机器可读）
```

## 应用（推荐用脚本）

```bash
scripts/mount_erofs.sh <基线>/odm.img    /mnt/odm
scripts/mount_erofs.sh <基线>/vendor.img /mnt/vendor
scripts/apply_xiaomi_account.sh --odm /mnt/odm --vendor /mnt/vendor --patch . --out out/
scripts/verify_xiaomi_account.sh --out out/ --baseline-odm /mnt/odm --baseline-vendor /mnt/vendor
```

脚本所做的一切（手工等价步骤）：

1. 复制基线树到 stage（保 xattr/mode/owner）
2. 按 `labels.tsv` 注入 `payload/` 文件（重复的跳过；`bin/` 置 0755，其余 0644，属主 root:root）
3. 写入 `selinux/odm_file_contexts`
4. 追加 `vendor_*.append` 到对应上下文文件
5. 追加两个 `.cil` 块到 `vendor_sepolicy.cil` 与 `vendor_sepolicy_debug.cil`
6. 补齐 `vintf/vendor.xiaomi.hardware.blackbox.xml`
7. **清除 stage 里所有 `security.selinux`**（保留 `security.capability`）——必须做，见规范文档 §4.1
8. 从基线 FUSE 挂载生成 **100% 覆盖**的 `--file-contexts`（目录+文件+符号链接），新文件用 `labels.tsv` 的标签
9. `mkfs.erofs -zlz4 -C262144 -b4096 -T0` → `fsck.erofs` → `img2simg`

## 离线验证通过的标准（2026-10-16 实测）

| 项 | 期望 |
|---|---|
| 注入文件标签 | 24（odm）/ 19（vendor）全部与 `labels.tsv` 一致 |
| 差分 | 常规文件只允许"新增"与"4+1 个 selinux 上下文/策略文件"变化；0 删除 |
| capability | 基线 9 个文件的 `security.capability` 零丢失 |
| 策略 | `secilc` 通过；neverallow 日志与基线一致 |
| 镜像 | `simg2img` 回读一致；镜像字节级哈希**每次构建可能不同**（取决于文件在镜像内的 inode 排列），判定标准是内容等价：本仓库脚本对同一基线重跑，与已交付镜像做过全量清单对比 —— odm 2739 / vendor 3898 个条目，标签、模式、属主、尺寸、内容哈希、capability、符号链接目标、目录元数据**零差异**。参考哈希（已交付版）：`odm.img=3a90d956…`、`vendor.img=dc491842…` |

## 实机验证（待做）

见 [../../docs/小米账号MTD依赖_修复方案.md](../../docs/小米账号MTD依赖_修复方案.md) 第 6 节。

## 回滚

重新刷入基线的 `odm.img` / `vendor.img` 即可（本补丁不触碰其它分区，也不写 userdata）。
若在整包里应用，成品包的 `_before_account_fix/` 目录保留了修改前镜像。
