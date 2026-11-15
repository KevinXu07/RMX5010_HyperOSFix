# soundtrigger_probe

用 root `app_process` 直接跟 `soundtrigger_middleware` / 高通 LSM 服务对话的测试工具，
不经过 VoiceTrigger。排查记录见 `docs/音质音效与小爱语音唤醒_排查.md` 第 2 节。

| 文件 | 作用 |
|---|---|
| `StTest.java` | 以任意 vendor uuid 加载一个 phrase 模型，设置置信度，等待检测；收到 `code=2` 回调即结束。可选播放 16 kHz PCM。环境变量 `ST_UV=1` 时 recognitionModes=3 并给用户 1 设置 ConfidenceLevel |
| `OvmsTest.java` | 按 OPPO OVoiceManagerService 的方式加载小布第一级模型（调用原厂 APK 里的 `s3.d#j` 打包） |
| `ExtendTest.java` | 加载旧版 VoiceTrigger 的 `com.qualcomm.listen.ListenSoundModel`，`query` + `extend` 用录音合成个人 udm |
| `MicTest.java` | 用指定 AudioSource 录几秒，打印每秒 RMS/峰值 |

## 构建

```bash
JAVA_HOME="C:/Users/Administrator/.gradle/jdks/eclipse_adoptium-17-amd64-windows.2"
"$JAVA_HOME/bin/javac" -source 11 -target 11 \
  -cp /d/AndroidSDK/platforms/android-37.0/android.jar -d cls StTest.java
/d/AndroidSDK/build-tools/36.0.0/d8.bat --min-api 30 --output out cls/*.class
```

每个工具单独编一个 dex。推到 `/data/local/tmp/ovt/` 后 `chmod 444`（DexClassLoader 要求只读）。

## 运行（root）

```sh
o=/data/local/tmp/ovt
# 小米模型（需先把小米 uuid 段加进 resourcemanager.xml）
CLASSPATH=$o/st.dex app_process /system/bin StTest <model> 61696d69-30f2-11e6-b0ac-40a8f03d3f1b <conf> <secs> [x.pcm ...]
# 小布
CLASSPATH=$o/ovms.dex app_process /system/bin OvmsTest $o/ovms.apk $o/OVMS_1st_wakeup.bin 69 0 120 3
# 合成个人模型
CLASSPATH=$o/ext.dex app_process /system/bin ExtendTest $o/vt_old.apk $o/xatx.uim $o/out.udm user1 training1.pcm ... training5.pcm
```

注意：

- 加载失败（INTERNAL_ERROR）会让 middleware 重启音频 HAL；实验前先停用 VoiceTrigger。
- `OVMS_1st_wakeup.bin` / `OVoiceManagerService.apk` 来自原厂 `my_product`，方案 uim / 旧版 APK 来自
  `移植修复方案/`，都不进仓库。
