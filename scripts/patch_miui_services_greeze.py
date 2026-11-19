#!/usr/bin/env python3
"""补丁 miui-services.jar：Greeze 推送默认值、双击亮屏开关同步、显示色彩桥、振动桥。

背景（docs/MiPush与FCM推送_诊断与修复.md）：
  HyperOS CN 的 GreezeManagerService 构造时把 mGmsLimitEnabled 设为
  isCnModel()（国行为 true）。息屏约 60 s 后 AurogonImmobulusMode 会把
  com.google.android.gms 快速冻结，直到亮屏才解冻，FCM 推送全部延迟。
  模块原来每次开机用调试命令 `dumpsys greezer IM GMS disable` 关掉它，
  并用 `dumpsys greezer LM add` 把微信/QQ 加进启动模式白名单。

本补丁把同样的默认值写进代码：
  1. GreezeManagerService.<init>：mGmsLimitEnabled 恒为 false。
     模块的 op13_fix_gms_unfreeze=0 仍可在运行时用调试命令恢复冻结。
  2. AurogonImmobulusMode.<init> 末尾：mLocalAllowList 追加
     com.tencent.mm、com.tencent.mobileqq、com.finshell.wallet。init() 只对该列表 addAll（不清空），
     updateCloudAllowList() 每次重建 mAllowList 都会先并入 mLocalAllowList，
     所以云端开关变化后也不会丢。

  3. TouchWakeUpFeatureManager.onGestureWakeupSettingsChanged(Z) 开头：把设置
     “双击亮屏”（Settings.System gesture_wakeup）的新状态写进 sys.rmx5010.dt2w
     （1/0）。HyperOS 原本把它交给小米 ITouchFeature HAL，本机没有；
     /odm/etc/init/rmx5010_touch.rc 跟着这个属性经 Oplus 触控 HAL 开关面板手势。
     开机时 SettingsObserver.refreshAllSettings 也会调用一次，所以属性每次开机都有值。

  4. DisplayFeatureManagerService.setDisplayFeature(IIII) 开头：调用
     com.android.server.display.RmxScreenColorBridge.onSetDisplayFeature(this, ...)，
     把 HyperOS 色彩设置桥接到 ColorOS 显示栈（本机没有小米 displayfeature HAL）。
  5. VibratorManagerServiceImpl.init(Context) 和 .startVibrationLockedInjector(Vibration)
     开头：调用 com.android.server.vibrator.RmxHapticBridge.onInit / onStartVibration
     （Sense HapticHooks 的镜像版）：开机后把小米私有振动 ID 加进 HAL 缓存的
     VibratorInfo；每次振动缩放之前把私有 ID 换成真我 HAL 能播的 0..12，
     键盘 / 桌面 / 系统界面的多段短振改成一次校准点击。

  6. ShortCutActionsUtils（ColorOS 钱包，Sense 的 WalletRuntimePermissions / 双击电源键）：
     <init>(Context) 末尾 RmxWalletBridge.onInit（钱包套件的 MIUIOP 10008 / 10020）；
     ShortCutActionsUtils 是第一次用到按键快捷操作时才创建的，所以第 5 项的
     VibratorManagerServiceImpl.init 里也调用一次（开机必定执行，重复调用无副作用）；
     launchDefaultWallet() 整体改为打开 FinShell 刷卡页（FinShell 没有 QAW 服务）；
     launchMiPay(String) 开头：FinShell 是 NFC 默认支付时同样打开刷卡页，否则走原逻辑。
  7. AurogonImmobulusMode（Sense 的 WalletFreezeExemption）：isNoRestrictApp 对钱包为真、
     isNoRestrictFreezeable 对钱包为假、TransfermLocalAllowList 加入钱包；
     第 2 项的 mLocalAllowList 也加入钱包。

  三个桥接类（patches/screen-color/RmxScreenColorBridge.java、
  patches/cos-wallet/RmxWalletBridge.java、
  patches/haptic/RmxHapticBridge.java）由 scripts/build_miui_services_bridges.sh
  编译成 patches/miui-services-bridges.dex，作为第三个参数传入，加到 jar 里
  下一个空闲的 classesN.dex。

用法：
  python3 patch_miui_services_greeze.py <miui-services.jar> <out.jar> [bridge.dex]
  需要 PATH 里有 baksmali / smali（Ubuntu 的 smali 包 2.5.x）。
  已打过补丁的 jar 再跑会报错退出（锚点不再存在），不会重复插入。
  每个类在哪个 dex 里自动定位（Greeze 在 classes2.dex，TouchWakeUp 在 classes.dex），
  只重新汇编涉及的 dex。
"""
import os
import re
import subprocess
import sys
import tempfile
import zipfile

GREEZE = "com/miui/server/greeze/GreezeManagerService.smali"
IMMOB = "com/miui/server/greeze/AurogonImmobulusMode.smali"
GMS_FIELD = "Lcom/miui/server/greeze/GreezeManagerService;->mGmsLimitEnabled:Z"
LOCAL_LIST = "Lcom/miui/server/greeze/AurogonImmobulusMode;->mLocalAllowList:Ljava/util/List;"
ALLOW = ("com.tencent.mm", "com.tencent.mobileqq", "com.finshell.wallet")
TOUCH_WAKE = "com/android/server/input/TouchWakeUpFeatureManager.smali"
DFMS = "com/android/server/display/DisplayFeatureManagerService.smali"
BRIDGE = "Lcom/android/server/display/RmxScreenColorBridge;"
VIBRATOR = "com/android/server/vibrator/VibratorManagerServiceImpl.smali"
HAPTIC = "Lcom/android/server/vibrator/RmxHapticBridge;"
DT2W_PROP = "sys.rmx5010.dt2w"
SHORTCUT = "com/miui/server/input/util/ShortCutActionsUtils.smali"
WALLET = "Lcom/android/server/RmxWalletBridge;"


def run(cmd):
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True)


def method_span(s, header_prefix):
    start = s.index(header_prefix)
    end = s.index(".end method", start)
    return start, end


def patch_gms(s):
    start, end = method_span(s, ".method public constructor <init>(")
    body = s[start:end]
    old = "    iput-boolean v4, p0, %s\n" % GMS_FIELD
    if body.count(old) != 1:
        raise SystemExit("GreezeManagerService.<init>: mGmsLimitEnabled anchor not found exactly once")
    i = body.index(old)
    # The next instruction overwrites v1 (new-instance v1, ArrayList), so v1
    # is free here.
    nxt = body[i + len(old):].lstrip().splitlines()[0]
    if not nxt.startswith(".line") and not nxt.startswith("new-instance v1,"):
        raise SystemExit("unexpected instruction after mGmsLimitEnabled: " + nxt)
    new = ("    # RMX5010: GMS quick-freeze off by default (was isCnModel())\n"
           "    const/4 v1, 0x0\n\n"
           "    iput-boolean v1, p0, %s\n" % GMS_FIELD)
    body = body.replace(old, new)
    return s[:start] + body + s[end:]


def patch_allow(s):
    start, end = method_span(s, ".method public constructor <init>(")
    body = s[start:end]
    if body.count("return-void") != 1:
        raise SystemExit("AurogonImmobulusMode.<init>: expected one return-void")
    if "RMX5010" in body:
        raise SystemExit("AurogonImmobulusMode already patched")
    add = ["    # RMX5010: keep WeChat/QQ out of the launch-mode freeze",
           "    iget-object v0, p0, %s" % LOCAL_LIST, ""]
    for pkg in ALLOW:
        add += ['    const-string v1, "%s"' % pkg, "",
                "    invoke-interface {v0, v1}, Ljava/util/List;->add(Ljava/lang/Object;)Z", ""]
    i = body.index("    return-void")
    body = body[:i] + "\n".join(add) + "\n" + body[i:]
    return s[:start] + body + s[end:]


def patch_dt2w(s):
    start, end = method_span(s, ".method private onGestureWakeupSettingsChanged(Z)V")
    body = s[start:end]
    if "RMX5010" in body:
        raise SystemExit("onGestureWakeupSettingsChanged already patched")
    if ".registers 6" not in body:
        raise SystemExit("onGestureWakeupSettingsChanged: unexpected register count")
    anchor = "    new-instance v0, Ljava/lang/StringBuilder;\n"
    if body.count(anchor) != 1:
        raise SystemExit("onGestureWakeupSettingsChanged: anchor not found exactly once")
    # v0/v1 are written by the next instructions, so they are free here.  A
    # denied property write must never take system_server down.
    add = """    # RMX5010: mirror the double-tap switch for /odm/etc/init/rmx5010_touch.rc
    const-string v0, "%s"

    if-eqz p1, :rmx_dt2w_off

    const-string v1, "1"

    goto :rmx_dt2w_set

    :rmx_dt2w_off
    const-string v1, "0"

    :rmx_dt2w_set
    :try_start_rmx_dt2w
    invoke-static {v0, v1}, Landroid/os/SystemProperties;->set(Ljava/lang/String;Ljava/lang/String;)V
    :try_end_rmx_dt2w
    .catch Ljava/lang/RuntimeException; {:try_start_rmx_dt2w .. :try_end_rmx_dt2w} :catch_rmx_dt2w

    goto :rmx_dt2w_done

    :catch_rmx_dt2w
    move-exception v0

    :rmx_dt2w_done
""" % DT2W_PROP
    i = body.index(anchor)
    body = body[:i] + add + body[i:]
    return s[:start] + body + s[end:]


def patch_dfms(s):
    start, end = method_span(s, ".method private setDisplayFeature(IIII)V")
    body = s[start:end]
    if "RmxScreenColorBridge" in body:
        raise SystemExit("setDisplayFeature already patched")
    anchor = ("    iget-object v0, p0, Lcom/android/server/display/DisplayFeatureManagerService;"
              "->mLock:Ljava/lang/Object;\n")
    if body.count(anchor) != 1:
        raise SystemExit("setDisplayFeature: anchor not found exactly once")
    add = ("    # RMX5010: screen colour bridge (no Xiaomi displayfeature HAL here)\n"
           "    invoke-static {p0, p1, p2, p3, p4}, %s->onSetDisplayFeature"
           "(Ljava/lang/Object;IIII)V\n\n" % BRIDGE)
    i = body.index(anchor)
    body = body[:i] + add + body[i:]
    return s[:start] + body + s[end:]


def insert_after_param(s, header, param_line, call, what):
    start, end = method_span(s, header)
    body = s[start:end]
    if "RmxHapticBridge" in body:
        raise SystemExit(what + " already patched")
    if body.count(param_line) != 1:
        raise SystemExit(what + ": .param line not found exactly once")
    i = body.index(param_line) + len(param_line)
    body = body[:i] + "\n    # RMX5010: haptic bridge (was Sense HapticHooks)\n" + call + "\n" + body[i:]
    return s[:start] + body + s[end:]


def patch_vibrator(s):
    s = insert_after_param(
        s, ".method public init(Landroid/content/Context;)V",
        '    .param p1, "context"    # Landroid/content/Context;\n',
        "    invoke-static {p1}, %s->onInit(Landroid/content/Context;)V\n\n"
        "    # RMX5010: ColorOS wallet AppOps; ShortCutActionsUtils is created lazily\n"
        "    invoke-static {p1}, %s->onInit(Landroid/content/Context;)V\n" % (HAPTIC, WALLET),
        "init")
    return insert_after_param(
        s, ".method public startVibrationLockedInjector(Lcom/android/server/vibrator/Vibration;)",
        '    .param p1, "vib"    # Lcom/android/server/vibrator/Vibration;\n',
        "    invoke-static {p1}, %s->onStartVibration(Ljava/lang/Object;)V\n" % HAPTIC,
        "startVibrationLockedInjector")


def insert_first(s, header, code, what):
    """Insert code before the first instruction of the method (after
    .registers, .param lines and annotations)."""
    start, end = method_span(s, header)
    body = s[start:end]
    if "RmxWalletBridge" in body:
        raise SystemExit(what + " already patched")
    depth, off = 0, 0
    lines = body.splitlines(True)
    for k, line in enumerate(lines):
        st = line.strip()
        if k and st.startswith(".annotation"):
            depth += 1
        elif k and st.startswith(".end annotation"):
            depth -= 1
        elif k and depth == 0 and st and not st.startswith(".") and not st.startswith("#"):
            break
        off += len(line)
    else:
        raise SystemExit(what + ": no code")
    if not re.search(r"^\s*\.registers ([1-9]\d*)$", body, re.M):
        raise SystemExit(what + ": unexpected register count")
    body = body[:off] + "    # RMX5010: ColorOS wallet (was Sense)\n" + code + "\n" + body[off:]
    return s[:start] + body + s[end:]


def patch_shortcut(s):
    # Boot hook: AppOps for the wallet set.
    start, end = method_span(s, ".method private constructor <init>(Landroid/content/Context;)V")
    body = s[start:end]
    if body.count("    return-void\n") != 1:
        raise SystemExit("ShortCutActionsUtils.<init>: expected one return-void")
    body = body.replace("    return-void\n",
                        "    # RMX5010: ColorOS wallet AppOps (was Sense)\n"
                        "    invoke-static {p1}, %s->onInit(Landroid/content/Context;)V\n\n"
                        "    return-void\n" % WALLET, 1)
    s = s[:start] + body + s[end:]
    # Double-click power with "launch_QAW_wallet": FinShell's swipe page.
    start, end = method_span(s, ".method private launchDefaultWallet()Z")
    s = (s[:start] + ".method private launchDefaultWallet()Z\n    .registers 2\n\n"
         "    # RMX5010: FinShell has no QuickAccessWalletService; open its swipe page\n"
         "    invoke-static {p0}, %s->launchDefaultWallet(Ljava/lang/Object;)Z\n\n"
         "    move-result v0\n\n    return v0\n" % WALLET + s[end:])
    # "mi_pay": the same page while FinShell is the NFC payment default.
    return insert_first(
        s, ".method private launchMiPay(Ljava/lang/String;)Z",
        "    invoke-static {p0, p1}, %s->onLaunchMiPay(Ljava/lang/Object;Ljava/lang/String;)I\n\n"
        "    move-result v0\n\n    if-ltz v0, :rmx_mipay_stock\n\n    return v0\n\n"
        "    :rmx_mipay_stock\n" % WALLET, "launchMiPay")


def patch_wallet_freeze(s):
    s = insert_first(
        s, ".method public isNoRestrictApp(Ljava/lang/String;)Z",
        "    invoke-static {p1}, %s->isWalletPackage(Ljava/lang/String;)Z\n\n"
        "    move-result v0\n\n    if-eqz v0, :rmx_norestrict\n\n    return v0\n\n"
        "    :rmx_norestrict\n" % WALLET, "isNoRestrictApp")
    s = insert_first(
        s, ".method public isNoRestrictFreezeable(Ljava/lang/String;I)Z",
        "    invoke-static {p1}, %s->isWalletPackage(Ljava/lang/String;)Z\n\n"
        "    move-result v0\n\n    if-eqz v0, :rmx_freezeable\n\n    const/4 v0, 0x0\n\n"
        "    return v0\n\n    :rmx_freezeable\n" % WALLET, "isNoRestrictFreezeable")
    return insert_first(
        s, ".method public TransfermLocalAllowList(Ljava/util/List;)V",
        "    invoke-static {p1}, %s->addWalletToAllowList(Ljava/util/List;)V\n" % WALLET,
        "TransfermLocalAllowList")


PATCHES = ((GREEZE, patch_gms), (IMMOB, patch_allow), (TOUCH_WAKE, patch_dt2w),
           (DFMS, patch_dfms), (VIBRATOR, patch_vibrator), (SHORTCUT, patch_shortcut),
           (IMMOB, patch_wallet_freeze))


def main(src, out, extra_dex=None):
    work = tempfile.mkdtemp(prefix="miui_services_")
    # Map every patched class to the dex that defines it (a class name can
    # also appear as a reference in other dex files).
    wanted = {"L" + rel[:-len(".smali")] + ";": rel for rel, _ in PATCHES}
    owner = {}
    with zipfile.ZipFile(src) as z:
        dexes = sorted(n for n in z.namelist() if n.startswith("classes") and n.endswith(".dex"))
        for name in dexes:
            path = os.path.join(work, name)
            data = z.read(name)
            with open(path, "wb") as f:
                f.write(data)
            if not any(c.encode() in data for c in wanted):
                continue
            listing = set(subprocess.run(["baksmali", "list", "classes", path],
                                         check=True, capture_output=True, text=True).stdout.split())
            for c, rel in wanted.items():
                if c in listing:
                    owner[rel] = name
    missing = [rel for rel, _ in PATCHES if rel not in owner]
    if missing:
        raise SystemExit("not found in %s: %s" % (src, missing))

    new_dex = {}
    for name in sorted(set(owner.values())):
        print("patching", name)
        smali_dir = os.path.join(work, name + ".smali")
        run(["baksmali", "d", os.path.join(work, name), "-o", smali_dir, "--api", "33"])
        for rel, fn in PATCHES:
            if owner[rel] != name:
                continue
            p = os.path.join(smali_dir, rel)
            s = open(p, encoding="utf-8").read()
            open(p, "w", encoding="utf-8").write(fn(s))
        new_dex[name] = os.path.join(work, name + ".patched")
        run(["smali", "a", smali_dir, "-o", new_dex[name], "--api", "33"])

    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
        last = None
        for zi in zin.infolist():
            if zi.filename in new_dex:
                zi2 = zipfile.ZipInfo(zi.filename, zi.date_time)
                zi2.compress_type = zi.compress_type
                zi2.external_attr = zi.external_attr
                zi2.internal_attr = zi.internal_attr
                zi2.create_system = zi.create_system
                zout.writestr(zi2, open(new_dex[zi.filename], "rb").read())
            else:
                zout.writestr(zi, zin.read(zi.filename))
            last = zi
        if extra_dex:
            # Next free classesN.dex; ART loads classes.dex, classes2.dex, ...
            # in order and stops at the first gap.
            n = len(dexes) + 1
            name = "classes%d.dex" % n
            if name in zin.namelist():
                raise SystemExit(name + " already exists")
            zi2 = zipfile.ZipInfo(name, last.date_time)
            zi2.compress_type = zipfile.ZIP_DEFLATED
            zi2.external_attr = 0o100644 << 16
            zi2.create_system = last.create_system
            zout.writestr(zi2, open(extra_dex, "rb").read())
            print("added", name, "from", extra_dex)
    print("output", out, os.path.getsize(out))


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    main(*sys.argv[1:])
