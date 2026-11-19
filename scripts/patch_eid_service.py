#!/usr/bin/env python3
"""补丁 ColorOS 钱包套件的 EidService.apk（com.oplus.eid）：连接 eID HAL 时跳过声明检查。

代替 COS-WALLET-FIX 的 hookOplusEidDeclaredServiceCompat：HyperOS 4 拒绝本机
eID 桥对 IServiceManager.isDeclared() 的查询（HAL 本身已注册、
/odm/etc/vintf/manifest/manifest_oplus_eid.xml 也声明了），桥因此到不了
waitForService，报状态 47。

EidService.getHalInstance() 里唯一的
    ServiceManager.waitForDeclaredService("vendor.oplus.hardware.eid.IEidDevice/default")
改为
    ServiceManager.waitForService(同一个名字)
即只去掉多余的声明探测；之后的 Binder 调用、SELinux 权限照旧，HAL 不在或无权限时照样失败。

用法：
  python3 patch_eid_service.py <EidService.apk> <out.zip>
签名块只有 0x0103 摘要；调用方用 scripts/apk_repack.py 拼回原签名块。
"""
import os
import re
import subprocess
import sys
import tempfile
import zipfile

OLD = "Landroid/os/ServiceManager;->waitForDeclaredService(Ljava/lang/String;)Landroid/os/IBinder;"
NEW = "Landroid/os/ServiceManager;->waitForService(Ljava/lang/String;)Landroid/os/IBinder;"
REL = "com/oplus/eid/EidService.smali"


def run(cmd):
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def main(src, out):
    work = tempfile.mkdtemp(prefix="eid_")
    with zipfile.ZipFile(src) as z:
        dexes = [n for n in z.namelist() if re.fullmatch(r"classes\d*\.dex", n)]
        if dexes != ["classes.dex"]:
            raise SystemExit("expected a single classes.dex, got %s" % dexes)
        open(os.path.join(work, "classes.dex"), "wb").write(z.read("classes.dex"))
    sd = os.path.join(work, "smali")
    run(["baksmali", "d", os.path.join(work, "classes.dex"), "-o", sd, "--api", "33"])
    p = os.path.join(sd, REL)
    s = open(p, encoding="utf-8").read()
    if s.count(OLD) != 1:
        raise SystemExit("waitForDeclaredService call found %d times" % s.count(OLD))
    open(p, "w", encoding="utf-8").write(s.replace(OLD, NEW))
    new = os.path.join(work, "classes.patched")
    run(["smali", "a", sd, "-o", new, "--api", "33"])
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(out, "w") as zout:
        for zi in zin.infolist():
            data = open(new, "rb").read() if zi.filename == "classes.dex" else zin.read(zi.filename)
            zi2 = zipfile.ZipInfo(zi.filename, zi.date_time)
            zi2.compress_type = zi.compress_type
            zi2.external_attr = zi.external_attr
            zi2.internal_attr = zi.internal_attr
            zi2.create_system = zi.create_system
            zout.writestr(zi2, data)
    print("output", out, os.path.getsize(out))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(*sys.argv[1:])
