# SELinux 闭包与 EROFS 重建规范

本文件是 RMX5010 移植项目的硬约束。踩过的坑都写在这里，构建脚本必须先读这一页。

## 1. 功能闭包清单

任何"加一个文件"的动作，实际要交付的是一整套：

```
文件本体 + mode/owner
  → file_contexts 标签（镜像内 xattr + 运行时 text contexts 都要一致）
  → exec type + domain（CIL 声明）
  → domain transition（init 拉起的服务）
  → init.rc（service 段）
  → VINTF manifest（AIDL/HIDL 实例，缺失会导致 HAL 侧 STATUS_BAD_VALUE）
  → service_contexts（binder 注册名 → service type）
  → property_contexts（它要读写的 prop）
  → domain 的 binder / 设备 / 文件许可
  → 运行期确认：进程域 / 服务注册 / 无 avc
```

**离线 fsck 通过 ≠ 闭包完整**：fsck 只检查标签有没有，不检查策略对不对。

## 2. 标签分级（不要用"万能域"）

| 类别 | 标签 | 理由 |
|---|---|---|
| HAL 可执行文件 | 专用 `hal_*_default_exec` | init 才能按 `typetransition` 进入对应域 |
| 共享库 `.so` | `vendor_file` | 基线里的库常带 `same_process_hal_file`/`vndk_sp_file` 等，乱标会破坏同进程 HAL |
| rc / vintf xml | `vendor_configs_file` | init 读配置用 |
| file_contexts 自身 | `file_contexts_file` | |
| 无域的第三方二进制 | `vendor_file` | 不可执行 → 不会以 init 域跑起来（危险！），也不会产生"无效上下文"告警 |

反例（已被实机证伪）：把整棵 payload 都标成 `hal_allocator_default_exec` → 卡第一屏。原因：基线的 `libbase`/`libcutils` 等被强行改标，破坏 VNDK/同进程 HAL 约束；且 `hal_allocator_default` 没有 AIDL 服务注册许可。

## 3. file_contexts 的 100% 覆盖生成法

镜像标签的来源是**构建时写进 inode 的 xattr**。生成方式：

```python
# 基线必须是 FUSE 挂载（erofsfuse）——fsck.erofs --extract 会丢 xattr！
for path in walk(baseline_mount):                 # 目录 + 文件 + 符号链接全要
    label = getxattr(path, "security.selinux", follow_symlinks=False)   # 已是完整上下文
    emit(re.escape(mountpoint + '/' + rel) + ' ' + label)               # 原样写，不要再包 u:object_r:
# 注入的新文件不在基线里，单独显式补齐（它们的标签是短类型名，需要自己拼完整）
```

要点：
- 基线**只能**用 FUSE 挂载读 xattr。`fsck.erofs --extract` 解出来的树**没有任何 xattr**，用它生成会得到空标签表。
- 符号链接和目录同样有标签；`follow_symlinks=False` 才能读到链接自身的标签。
- 注入文件必须显式补条目（遍历基线时看不到它们）。

## 4. 三个致命陷阱

### 4.1 stage 树上的源 xattr 会被 mkfs 二次包装

从 FUSE 基线 `cp -a` 复制出来的 stage，其文件自带 `security.selinux` xattr。用 `--file-contexts` 重建时，**带着源 xattr 的条目会被写成 `u:object_r:u:object_r:xxx:s0:s0`**（实测：2700+ 个条目全部中招；不带 xattr 的新文件反而正确）。

处理：

```bash
# 构建前清掉 stage 里的 security.selinux（保留 security.capability！）
python3 - <<'PY'
import os
for base in (stage_odm, stage_vendor):
    for dp, dn, fn in os.walk(base):
        for n in fn + dn:
            try: os.removexattr(os.path.join(dp, n), 'security.selinux', follow_symlinks=False)
            except OSError: pass
PY
```

清空后 `--file-contexts` 成为唯一标签来源 —— 因此第 3 节的覆盖率必须是 100%。

### 4.2 清 xattr 不等于能清 capability

`security.capability` 是功能性的（如 `bin/imsdaemon` 等需要在 data 目录操作的能力），**不能**一起清掉。构建后回读核对：

```python
# 基线与新镜像逐文件对比 capability xattr，必须零丢失
```

### 4.3 验证必须重新挂载

`erofsfuse` 的挂载点会存活到 WSL 关闭；脚本里 `mountpoint -q || mount` 的写法会在第二次运行时**读到旧镜像**，得出错误结论。校验脚本必须先 `fusermount3 -u` 卸载，再重新挂载。

## 5. mkfs.erofs 参数（按分区）

| 分区 | 参数 |
|---|---|
| system / system_ext / product | `-zlz4hc -b4096 -T0 --mount-point=/<mp>`（+ 拼合的 plat/system_ext/product contexts） |
| odm / vendor | `-zlz4 -C262144 -b4096 -T0 --mount-point=/odm|/vendor`（big pcluster，与原厂 superblock 特征一致） |

原厂 odm/vendor superblock 特征参考：`compr_algs: lz4`、features 含 `big_pcluster`。用 `dump.erofs -s` 核对。

## 6. 策略改动与校验

- 追加块只写**普通声明 + allow/typetransition**（不引入 `mapping`/`projection` 之类复杂结构），保证运行期重编译的兼容面最小。
- 离线校验（本机 secilc 可能低于设备 libsepol 版本，`nlmsg` 等新语法需要先剔除，仅用于校验）：

```bash
secilc -m -M true -G -N -c 30 \
  plat_sepolicy.cil mapping/202404.cil mapping/202404.compat.cil \
  vendor/plat_pub_versioned.cil system_ext_sepolicy.cil product_sepolicy.cil \
  vendor_sepolicy.cil
```

- neverallow 对照法：用严格模式各编译一次**基线**与**修改后**策略，diff 两份日志；只在两处完全相同才说明没有引入新 neverallow 冲突。
- 本机型**不需要**重生成 `precompiled_sepolicy`（启动时从 `.cil` 重编译；改 `.cil` 会让伴随的 `*.sha256` 不匹配，正好触发重编译）。

## 7. 构建后必做的五项验证

1. `fsck.erofs`（仅对 `.raw` 有效；sparse 上报 invalid superblock 属误报）
2. `simg2img` 回读并与 raw 逐字节比较（sparse 完整性）
3. 重新挂载新镜像，逐文件比对：标签 / 模式 / 属主 / 大小 / 内容哈希（忽略目录尺寸与符号链接权限位）
4. `security.capability` 零丢失
5. `sha256sum` 入清单，成品包 `verify_package.ps1 -Strict` 全绿
