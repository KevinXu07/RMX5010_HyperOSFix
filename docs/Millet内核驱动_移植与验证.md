# 小米 Millet 内核驱动：移植与验证（2026-11-13）

## 问题

HyperOS 的 Greeze 用 cgroup freezer 冻结后台应用，要靠小米的 millet 内核驱动在以下三种情况把应用解冻：

- 网络包到达（`reportNet`，解冻原因 `packet`）
- 信号
- binder 调用

驱动通过 netlink 协议 31（`ro.millet.netlink`）与用户态通信。RMX5010 是 Oplus 内核，没有这个驱动，导致：

- `millet_monitor` 每约 9 秒崩溃重启一次（`MILLET_EPOLL: failed to create socket for type 1`）。
- Greeze 一直是 `MilletEnable=false`，收到网络包也不会解冻应用。
- 微信、QQ 被冻结后只能等闹钟才醒，消息延迟 1–2 分钟成批到达。

完整背景见 `docs/MiPush与FCM推送_诊断与修复.md` 第 4 节。

## 来源

驱动不是移植源码，而是直接使用底包现成的模块：donor 是小米 15 Pro haotian（OS4.0.0.19），SoC 同为 SM8750，内核同为 android15-6.6 GKI。模块位于 haotian 的 **vendor_boot ramdisk**（不在 vendor_dlkm），`lib/modules/` 下共 7 个：

| 模块 | 依赖 | 作用 |
|---|---|---|
| `millet_core.ko` | — | netlink 31，创建 `/proc/millet` |
| `binder_gki.ko` | millet_core | binder 钩子：`android_vh_binder_{trans,reply,preset,wait_for_work,alloc_new_buf_locked}` |
| `millet_pkg.ko` | millet_core | netfilter 钩子，按 uid 上报网络包 |
| `millet_hs.ko` | millet_core | 握手（`HANDSHK_TYPE` = 6） |
| `millet_binder.ko` | binder_gki、millet_core、millet_pkg | binder 上报 |
| `millet_sig.ko` | millet_core | 信号钩子 `android_vh_do_send_sig_info` |
| `millet_oem_cgroup.ko` | — | 使用 `freezer_cgrp_subsys` |

加载顺序（来自 donor 的 `modules.dep`）：core → binder_gki → pkg → hs → binder → sig → oem_cgroup。

## 兼容性核对（静态）

- **vermagic**：模块是 `6.6.57-android15-8-gbc807ab2c5a8-4k`，本机内核是 `6.6.89-android15-8-g7e1f3c083cc6-abogki467167594-4k`。开启 modversions 时内核只比较 vermagic 中版本号之后的部分（`SMP preempt mod_unload modversions aarch64`），这部分一致。
- **CRC**：7 个模块的 `__versions` 与本机 `/proc/kallsyms`、本机 system_dlkm/vendor_dlkm/vendor_boot 共 1066 个模块的 CRC 对比，结果为 0 处不一致、0 个缺失符号。只有 `freezer_cgrp_subsys` 一个符号在参考模块里没出现过，无法核对 CRC，但它存在于 kallsyms。
- **`struct module` 布局**：`.gnu.linkonce.this_module` 大小为 0x600，`cleanup_module` 的重定位偏移为 0x5b8，与 GKI 一致（参见 `docs/内核模块构建_KCFI与struct-module布局.md`）。
- **钩子**：只用到 `android_vh_*`，可以多方注册，不会与 `oplus_sys_hans`、`oplus_binder_strategy` 冲突；没有用到 `android_rvh_*`。
- **netlink 31**：加载前本机没有任何 socket 使用协议 31。

## 握手与 Greeze 启用

1. 加载后 `/proc/millet/{millet_stat,version}` 出现，netlink 31 可用。`millet_monitor` 输出 `all 3 sockets registered, entering event loop`，不再崩溃。它为类型 1（SIG）、2（BINDER）、5（PKG）各开一个 socket，并发送 loopback，内核原样回送。
2. `millet_monitor` 的类型 6 回调（`HANDSHK`）会调用 `greezer` 服务的 `registerMonitor(token, 1/2/3)`。Greeze 收齐 3 个（`mRegisteredMonitor == 7`）后，在 `reportLoopOnce` 中置 `milletEnable=true`。
3. 内核侧 `millet_hs` 只有在收到用户态发来的类型 6 消息时才回 `HANDSHK`，这一步由 Greeze 的 `nLoopOnce` 触发。热加载时 Greeze 早已启动，所以 `monitor=false (0)`。执行 `cmd greezer loop`（Shell 命令，内部调用 `GreezeManagerServiceNative.nLoopOnce()`）后，变为 `monitor=true (7)`、`MilletEnable=true`。

开机流程中，模块在 post-fs-data 阶段加载，早于 system_server 和 `millet_monitor`，按理会走原厂顺序自动完成。service.sh 中的 `ensure_millet` 作为兜底：开机完成后 60 秒内若仍是 `MilletEnable=false`，就执行 `cmd greezer loop`，必要时重启 `millet_monitor`，最多重试 3 次。

## 实机验证（热加载，2026-11-13 17:42–17:59）

- 7 个模块的 `insmod` 均返回 0，dmesg 无 Oops 或 WARN，系统运行正常。
- `dumpsys greezer`：`enable=true`、`monitor=true (7)`、`MilletEnable=true`、`freezebinder_enable:true supportEnable=true`。
- Greeze 冻结和解冻记录（90 秒）：
  ```
  T17:58:09.158 FZ   uid = 10313 reason : packet
  T17:58:14.156 THAW uid = 10313 reason : packet      # QQ 收到网络包即解冻
  T17:58:27.771 FZ   uid = 10314 reason : check binder
  T17:58:27.786 THAW uid = 10314 reason : check_binder # 微信：有 binder 往来，放弃冻结
  ```
  修复前不存在 `packet` 和 `check_binder` 这两类原因。
- 内核日志中可以看到 `millet_millet-binder: bindersend found=1 ...`，binder 钩子在工作。

## 载体与开关

- 文件：`kernel-src/ksu-module/millet/*.ko`（共 7 个，628 KB）、`kernel-src/ksu-module/millet_fix.sh`。
- `post-fs-data.sh` 调用 `load_millet`。只在 `6.6.*-android15-*` 内核上加载；某个模块加载失败就停止，不再加载后面的模块。
- `service.sh` 调用 `ensure_millet`。
- `ctl.sh status` 新增 `millet_loaded`、`millet_greeze` 两项。
- **关闭方法**：`touch /data/adb/rmx5010_millet_off` 后重启。post-fs-data 阶段读不到 Settings，所以用文件作开关。若开机异常，可以用 KSU 安全模式（开机时按音量键）禁用整个模块。
- 微信、QQ 的 LM 白名单（`apply-greeze-allow`）暂时保留。有了 millet，即使它们被冻结也能被网络包唤醒；去掉白名单省电，但需要先用真实消息实测确认不影响收消息。

## 重启复验（1.7.19 安装后，2026-11-13 18:05）

- post-fs-data 自动加载 7 个模块（`audio.log`：`millet: loaded`）。
- Greeze 开机即 `MilletEnable=true`、`monitor=true (7)`（`boot.log`：`greeze MilletEnable=true after 0s`），不需要 `cmd greezer loop` 兜底，说明开机顺序下握手会自动完成。
- 开机后 `millet_monitor` 的 `failed to create socket` 次数为 0。`ctl.sh status` 显示 `millet_loaded=1`、`millet_greeze=1`。
- dmesg 唯一的 WARNING 来自 cnss2 的 `cnss_disable_dev_sol_irq`（WLAN 开机校准），与 millet 无关。

## 真实消息实测（息屏，另一台设备发送）

QQ（18:15）：
```
18:14:45.17 FZ   10313 reason: packet
18:15:29.93 THAW 10313 reason: packet       # 消息到达，millet 唤醒
18:15:33.38 notification_enqueue com.tencent.mobileqq   # 之后 36.5 / 42.7 各一条
18:15:34.00 screen_toggled 1
```

微信（18:27），用户确认"马上弹出"：
```
18:25:01.19 FZ   10314 reason: packet
18:26:11.70 THAW 10314 reason: packet       # 冻结中被网络包唤醒
18:26:21.82 FZ   10314 → 13 ms 后 THAW check_binder（此后每 5 s 一轮）
18:27:08.08 notification_enqueue com.tencent.mm
18:27:08.70 screen_toggled 1
```

修复前，同样场景需要等 `THAW reason: alarm`，消息延迟 1–2 分钟后成批到达。

## 观察项

- 息屏期间 Greeze 每 5 s 尝试冻结一次微信，millet 发现 binder 未完成后在约 10 ms 内放开（`check binder` / `check_binder`），实测 3 分钟内 19 轮。这是 Greeze 自身的策略，需要观察一两天耗电。
- 微信、QQ 的 LM 白名单仍保留。耗电观察结束后，再决定是否撤掉（`settings put global op13_fix_greeze_allow none`）。
