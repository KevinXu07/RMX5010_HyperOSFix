#!/usr/bin/env python3
"""补丁 miui-services.jar：FingerprintServiceStubImpl.isFpHardwareDetected() 直接返回 true。

背景（2026-10-26 实机定位）：
  设置页指纹入口的可用性 = FingerprintEntryPreferenceController.getAvailabilityStatus()
  -> FingerprintHelper.isHardwareDetected()
  -> FingerprintManager.isHardwareDetected()
  -> system_server Sensor.isHardwareDetected(halInstance)
     = ServiceManager.checkService(...) != null
       && FingerprintServiceStub.getInstance().isFpHardwareDetected()

  小米在 miui-services.jar 的实现 FingerprintServiceStubImpl 里读
  persist.vendor.sys.fp.vendor，为空或 "none" 就返回 false。
  该属性在 RMX 上标签是 vendor_system_prop，system_server 无 file read 权限
  （策略里只有 hal_mtdservice_default / vendor_qti_init_shell 能读），
  因此永远读到空串 -> isHardwareDetected=false -> 设置隐藏指纹入口。

  在 vendor 策略里给 system_server 加 allow 会触发 Treble neverallow
  （OS3 实测会卡一屏），所以直接改小米自己的桩：与 Oplus 基类
  FingerprintServiceStub.isFpHardwareDetected() 的行为一致（恒 true）。

用法：
  python3 patch_miui_services_fp_stub.py <miui-services.jar> <out.jar>
  需要 PATH 里有 baksmali / smali（Ubuntu 的 smali 包 2.5.x）。
"""
import os
import subprocess
import sys
import tempfile
import zipfile

TARGET = ("com/android/server/biometrics/sensors/fingerprint/"
          "FingerprintServiceStubImpl.smali")
METHOD = "isFpHardwareDetected"
NEW_BODY = """.method public isFpHardwareDetected()Z
    .registers 2

    const/4 v0, 0x1

    return v0
.end method"""


def run(cmd):
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True)


def main(src, out):
    work = tempfile.mkdtemp(prefix="miui_svc_")
    dex = os.path.join(work, "classes.dex")
    with zipfile.ZipFile(src) as z:
        with open(dex, "wb") as f:
            f.write(z.read("classes.dex"))

    smali_dir = os.path.join(work, "smali")
    run(["baksmali", "d", dex, "-o", smali_dir, "--api", "33"])
    target = os.path.join(smali_dir, TARGET)
    s = open(target, encoding="utf-8").read()
    start = s.index(".method public %s()Z" % METHOD)
    end = s.index(".end method", start) + len(".end method")
    s = s[:start] + NEW_BODY + s[end:]
    open(target, "w", encoding="utf-8").write(s)

    new_dex = os.path.join(work, "patched.dex")
    run(["smali", "a", smali_dir, "-o", new_dex, "--api", "33"])

    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
        for zi in zin.infolist():
            if zi.filename == "classes.dex":
                zi2 = zipfile.ZipInfo(zi.filename, zi.date_time)
                zi2.compress_type = zi.compress_type
                zi2.external_attr = zi.external_attr
                zi2.internal_attr = zi.internal_attr
                zi2.create_system = zi.create_system
                zout.writestr(zi2, open(new_dex, "rb").read())
            else:
                zout.writestr(zi, zin.read(zi.filename))
    print("output", out, os.path.getsize(out))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
