# 音频卡顿：appname 参数补丁（RMX5010）

状态（2026-10-26）：

- 已完成 RMX 0.19 音频策略库的**重新定位**，不是套用 OP13 固定偏移。
- 8 个 `appname` 写入调用（`blr x8`）已改为 `nop`，只改了 8 条 4 字节指令。
- `post-fs-data.sh` 在 init 的 mount namespace 中 bind-mount 补丁库，audioserver
  启动前生效；实测目标哈希与补丁库一致，audioserver 正常运行。
- 铃声预览冒烟通过；**主观卡顿/长时间播放回归还需要用户实际听**。

## 1. 根因

Xiaomi/Oplus 音频策略在每次输出/输入启动时向 QTI HAL 写入
`appname=+/-<package>` 参数。RMX 的 QTI HAL 不认识该 vendor 参数，触发
standby/reopen，表现为音频卡顿。OP13 的做法是保留其余逻辑，只把这些
`setParameters` 调用 NOP 掉。

## 2. RMX 库与调用点

```text
/system_ext/lib64/libaudiopolicymanagerimpl.so
/system_ext/lib64/libmiaudiopolicymanager.so
```

原始/补丁 SHA-256：

```text
libaudiopolicymanagerimpl.so
  原始 a48b94d1081b10678e5c117b4483c86c37d8156a4fda39d4db8e70a3be7d385b
  补丁 0f8c1e682a6407af053e7669f93459d6e284631530722b5e87d53bee7c2b1ea4

libmiaudiopolicymanager.so
  原始 9352ea35fae6d165ecf0390763a97fe9c097b134a299a73f2d9c1ae8a6df70a0
  补丁 d9b0f1ae851bf28ab15f380603eac1bf21f57eb943e717d783e630d46fb4e70e
```

补丁字节：

```text
blr x8 : 00 01 3F D6
nop    : 1F 20 03 D5
```

调用点（全部先验证原始 4 字节为 `00 01 3F D6`）：

| 库 | 偏移 | 所在函数 |
|---|---|---|
| libaudiopolicymanagerimpl.so | 0x3DC80 | `AudioPolicyManagerImpl::setAppNameParameter` |
| libaudiopolicymanagerimpl.so | 0x3DCE4 | `AudioPolicyManagerImpl::setAppNameParameter`（appname + track） |
| libaudiopolicymanagerimpl.so | 0x4144C | `AudioPolicyManagerImpl::setParametersForSystemClient` |
| libmiaudiopolicymanager.so | 0x1A39C | `MiAudioPolicyManager::startInput`（+system.app） |
| libmiaudiopolicymanager.so | 0x1A48C | `MiAudioPolicyManager::startInput`（-system.app） |
| libmiaudiopolicymanager.so | 0x1A548 | `MiAudioPolicyManager::startInput` |
| libmiaudiopolicymanager.so | 0x1A6F8 | `MiAudioPolicyManager::stopInput` |
| libmiaudiopolicymanager.so | 0x1A77C | `MiAudioPolicyManager::stopInput` |

注意：OP13 文档记录的是 7 个点（impl 2 个）。RMX 0.19 的
`setAppNameParameter` 内部有两次 `setParameters`（单独的 appname 和
appname + track name），加上 `setParametersForSystemClient`，所以 impl 是
3 个点。`libmiaudiopolicymanager.so` 的 5 个偏移与 OP13 完全一致。

## 3. 挂载方式

`kernel-src/ksu-module/post-fs-data.sh`：

1. `chcon u:object_r:system_lib_file:s0` 给补丁库；
2. `nsenter -t 1 -m -- mount --bind <补丁库> /system_ext/lib64/<库>`；
3. 在 init namespace 内重新 `sha256sum` 目标文件，写 `audio.log`。

`post-fs-data.sh` 在 audioserver 启动前执行，因此不需要重启 audioserver，
也不会对 `/system_ext` 做任何写操作。重启后挂载消失，脚本会重新应用。

实测 `audio.log`：

```text
mounted libaudiopolicymanagerimpl.so
mounted libmiaudiopolicymanager.so
target libaudiopolicymanagerimpl.so=0f8c1e...
target libmiaudiopolicymanager.so=d9b0f1...
```

audioserver：

```text
u:r:audioserver:s0  audioserver  pid 2365
u:r:hal_audio_default:s0 audioserver pid 2070
```

## 4. 验证与残余

已做：

- 8 个补丁点逐字节确认；
- 仅 8×4 字节差异，无其他改动；
- bind mount 目标哈希匹配；
- 打开设置铃声预览，AudioFlinger/AudioOut 正常创建，无
  `FATAL`/`AudioTrack` 错误。

未做：

- 主观卡顿、长时间音乐/视频、蓝牙 A2DP/LHDC 并发、通话/录音回归；
- 播放大音量/低延迟游戏场景。

如果主观听感仍有卡顿，下一步是抓 `dumpsys media.audio_flinger`、
`logcat -b all` 的 `AudioFlinger`/`AudioPolicyManager`，确认是否还有非
`appname` 的参数路径。

## 5. 回退

```bash
# 设备上
su -c 'rm /data/adb/modules/rmx5010_fod_bridge/post-fs-data.sh'
su -c 'rm -rf /data/adb/modules/rmx5010_fod_bridge/audio'
# 重启后恢复原库
```

仓库内对应文件是 `kernel-src/ksu-module/post-fs-data.sh` 和
`kernel-src/ksu-module/audio/`。

## 6. 结论

音频卡顿的“appname vendor 参数”根因在 RMX 0.19 上同样存在，补丁已按本机
库重新定位并安全挂载。是否彻底解决，需要用户实际播放一首长音频/视频后确认。
