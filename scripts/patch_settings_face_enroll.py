#!/usr/bin/env python3
"""给 Settings.apk 打补丁：修复人脸录入卡在进度环（mFaceEnrollAnimating 死锁）。

根因（2026-10-26 实机日志 + 反编译确认）：
  NewMultiFaceEnrollFragment.initProgressView() 给 1~4 号进度圆环挂了
  $15.onAnimationEnd 监听器，唯独 0 号圆环（progress_0）没挂。
  startFaceInputProgressAnimation() 首次播放 0 号圆环并置
  mFaceEnrollAnimating=true；该标志全 APK 只有 $15.onAnimationEnd 会清 false，
  于是首次动画播完无人回调 → 标志永远 true → 后续每次回调都被 guard 挡掉，
  界面停在第一段进度环。HAL/framework 侧录入实际已成功（rem=0、faceid 已写入）。

补丁：给 0 号圆环补挂同一个 $15 监听器。

用法：
  python3 patch_settings_face_enroll.py <Settings.apk> <out.apk>
需要 PATH 里有 baksmali / smali（Debian/Ubuntu 的 smali 包，2.5.x）。
"""
import os
import struct
import subprocess
import sys
import tempfile
import zipfile

TARGET_DEX = "classes3.dex"
SMALI_REL = ("com/android/settings/faceunlock/"
             "MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment.smali")
INSERT = [
    "",
    "    # FIX: attach animator listener to progress circle 0 as well",
    "    new-instance v2, Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment$15;",
    "",
    "    invoke-direct {v2, p0}, Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment$15;-><init>(Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;)V",
    "",
    "    invoke-virtual {v0, v2}, Lcom/airbnb/lottie/LottieAnimationView;->addAnimatorListener(Landroid/animation/Animator$AnimatorListener;)V",
]


def run(cmd, **kw):
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True, **kw)


def main(src, out):
    work = tempfile.mkdtemp(prefix="settings_face_")
    dex = os.path.join(work, TARGET_DEX)
    with zipfile.ZipFile(src) as z:
        with open(dex, "wb") as f:
            f.write(z.read(TARGET_DEX))

    smali_dir = os.path.join(work, "smali")
    run(["baksmali", "d", dex, "-o", smali_dir, "--api", "33"])
    target = os.path.join(smali_dir, SMALI_REL)

    lines = open(target, encoding="utf-8").read().split("\n")
    hit = None
    for i, line in enumerate(lines):
        if "miui_face_input_progress_0" in line:
            for j in range(i, min(i + 10, len(lines))):
                if "LottieAnimationView;->setAnimation(I)V" in lines[j]:
                    hit = j
                    break
            break
    if hit is None:
        raise SystemExit("setAnimation for progress_0 not found; APK version mismatch?")
    lines[hit + 1:hit + 1] = INSERT
    open(target, "w", encoding="utf-8").write("\n".join(lines))
    print("patched at line", hit + 1)

    new_dex = os.path.join(work, "patched.dex")
    run(["smali", "a", smali_dir, "-o", new_dex, "--api", "33"])

    # 重新打包，仅替换 classes3.dex，其余条目与顺序不变
    tmp = out + ".tmp"
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
        for zi in zin.infolist():
            if zi.filename == TARGET_DEX:
                zi2 = zipfile.ZipInfo(zi.filename, zi.date_time)
                zi2.compress_type = zi.compress_type
                zi2.external_attr = zi.external_attr
                zi2.internal_attr = zi.internal_attr
                zi2.create_system = zi.create_system
                zout.writestr(zi2, open(new_dex, "rb").read())
            else:
                zout.writestr(zi, zin.read(zi.filename))

    # 拼回原签名块（预置分区扫描路径，见 docs/内核模块构建 同源说明）
    data = open(tmp, "rb").read()
    i = len(data) - 22
    while i >= 0 and data[i:i + 4] != b"PK\x05\x06":
        i -= 1
    cd_off = struct.unpack("<I", data[i + 16:i + 20])[0]
    orig = open(src, "rb").read()
    j = orig.rfind(b"PK\x05\x06")
    o_cd_off = struct.unpack("<I", orig[j + 16:j + 20])[0]
    assert orig[o_cd_off - 16:o_cd_off] == b"APK Sig Block 42", "original has no v2 signing block"
    blk_len = struct.unpack("<Q", orig[o_cd_off - 24:o_cd_off - 16])[0]
    block = orig[o_cd_off - 8 - blk_len:o_cd_off]
    pre, tail = data[:cd_off], data[cd_off:]
    eocd = bytearray(tail[-22:])
    eocd[16:20] = struct.pack("<I", cd_off + len(block))
    with open(out, "wb") as f:
        f.write(pre + block + tail[:-22] + bytes(eocd))
    os.remove(tmp)
    print("output", out, os.path.getsize(out))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
