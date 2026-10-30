# QESDK/QAPE 服务崩溃循环与 qseelogd 空转修复

日期：2026-10-28
载体：KSU 模块 `rmx5010_fod_bridge` 1.3.9（`qesdk_fix.sh`）

> 游戏 24fps 的直接原因不是 QESDK，而是 GameManager 模式回退到 `standard`；
> 见 `docs/游戏24fps诊断_ACE与帧率策略.md`。本修复解决 QAPE 崩溃、qseelogd
> 空转和系统负载。

## 现象

- `vendor.qesdk-securitymgr`、`vendor.qsap.qapeservice`、
  `vendor.qti.syshealthmon-service` 每隔约 5 秒同时死一次，logcat：

  ```text
  qesdk-secmanager: libminijail[24210]: blocked syscall: lseek
  Service 'vendor.qesdk-securitymgr' received SIGSYS
  QESDK has detected a Service Plugin crash: [{0x13, 2651}{0x63, 2681}]
  ```

- QESDK/QAPE 永远到不了 READY，QAPE 的 `/vendor/etc/perf/qapegameconfig.txt`
  游戏性能策略无法下发。
- `qseelogd` 因 TrustZone 日志暴涨持续轮转 `/data/cache/qseelog`，
  单进程约 110% CPU；开机后 load average 14~16，swap 用到 7.1GB。

## 根因

ColorOS 16 vendor 的三份 seccomp allow-list 缺少 `lseek`：

```text
/vendor/etc/seccomp_policy/qesdksec.policy
/vendor/etc/seccomp_policy/qsap_qapeservice.policy
/vendor/etc/seccomp_policy/syshealthmon.policy
```

对应二进制实际会调用 `lseek`，被 libminijail 拦成 SIGSYS；init 把同组服务一起
杀掉。`qseelogd` 只是被崩溃日志拖垮的受害者，不是根因。

## 修复

`qesdk_fix.sh`：

1. 复制原 policy 到 `/data/local/tmp/qesdk_<name>`；
2. 追加 `lseek: 1`；
3. `chcon u:object_r:vendor_configs_file:s0`（保持原 vendor 配置标签）；
4. `nsenter -t 1 -m -- mount --bind` 到 init 的 mount namespace；
5. `service.sh` 重启三个服务；
6. `persist.sys.qseelogd=false`，利用厂商自带的
   `init.qseelogd.rc` 开关停掉日志守护。

执行位置在 `post-fs-data.sh`（早于 `class hal`/`class main` 启动服务），
`service.sh` 再做一次兜底并重启服务。模块更新无需改分区、无需重签。

## 重启后验证（2026-10-28 00:14）

```text
boot.log:
  qesdk policy: 0
  qseelogd disabled
  qesdk services restarted

qesdk-secmanager          running
qsap_qapeservice          running
vendor.qti.syshealthmon   running
qseelogd                  stopped
persist.sys.qseelogd      false

/vendor/etc/seccomp_policy/qesdksec.policy:1
/vendor/etc/seccomp_policy/qsap_qapeservice.policy:1
/vendor/etc/seccomp_policy/syshealthmon.policy:1
```

swap 从 7.1GB 降到 489MB（开机 8 秒采样），qseelogd 不再出现轮转日志。

## 风险与回退

- 只是给三个沙箱允许 `lseek`，不降低 SELinux 域隔离。
- 关闭 `qseelogd` 只影响 TZ 日志落盘，不影响 QESDK/QAPE 功能；厂商自身也提供
  该开关（`ro.mi.os.logs.romtype=perf-test` 会停掉它）。
- 回退：删除模块或删除 `qesdk_fix.sh` 的调用，重启即可恢复原 policy 和日志守护。
- 游戏 24fps 是否随 QAPE 恢复而解决，仍需进战斗验证；本修复首先解决的是
  CPU 空转、swap 压力和 QAPE 功能缺失。
