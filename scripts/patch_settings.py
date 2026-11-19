#!/usr/bin/env python3
"""Patch HyperOS Settings.apk for RMX5010 (image versions of Sense Settings hooks).

  1. SettingsFeatures.isSupportSettingsHaptic(Context): the first
     `const/4 v0, 0x0` becomes 0x1, so the method reports support and the
     haptic settings page (the "billiards" page) works.
  2. "My device" parameters (Sense DeviceParamsHooks): DeviceParamsManager
     .getBasicParams/.getCameraParams, DeviceServiceCache.readBasicInfo/
     .readCameraInfo return this phone's real specs as the JSON the page
     expects; MiuiAboutPhoneUtils.getDeviceMarketName returns the real name.
     Without it the page shows the spoofed Xiaomi model fetched from Xiaomi's
     device-info service.
  3. Face enrollment (Sense FaceEnrollHooks): initProgressView() gives progress
     circles 1..n an AnimatorListener ($15) whose onAnimationEnd clears
     mFaceEnrollAnimating, but not circle 0, so enrollment stalls at the first
     circle.  Add the same listener to circle 0.

The APK written here has no signing block; scripts/merge_module_into_image.sh
zipaligns it and splices the original block back (scripts/apk_sigblock.py).

usage: python3 patch_settings.py <Settings.apk> <out.apk>
needs baksmali / smali in PATH.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import zipfile

FEATURES = "com/android/settings/utils/SettingsFeatures.smali"
PARAMS = "com/android/settings/device/DeviceParamsManager.smali"
CACHE = "com/android/settings/device/DeviceServiceCache.smali"
ABOUT = "com/android/settings/device/MiuiAboutPhoneUtils.smali"
FACE = "com/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment.smali"
FACE_CLS = "Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;"
LOTTIE = "Lcom/airbnb/lottie/LottieAnimationView;"

MARKET_NAME = "真我GT7 Pro"
PROCESSOR = "骁龙8至尊版移动平台"
BATTERY = "6500mAh"
REAR_CAMERA = "50MP+50MP+8MP"
SCREEN_SIZE = "6.78″"
RESOLUTION = "2780*1264"
FRONT_CAMERA = "16MP"


def basic_json():
    items = [
        ("处理器", PROCESSOR), ("电池容量", BATTERY), ("后置摄像头", REAR_CAMERA),
        ("屏幕尺寸", SCREEN_SIZE), ("分辨率", RESOLUTION),
        # RAM stays the stock placeholder: the presenter fills in the real
        # total plus extended RAM itself.
        ("运行内存", "xxxx")]
    return json.dumps({
        "Mishop": {"RightValue": "", "ShowRedDot": "false", "Url": ""},
        "BasicInfoToggle": "1",
        "BasicItems": [{"Title": t, "Summary": s, "Index": str(i)}
                       for i, (t, s) in enumerate(items)],
    }, ensure_ascii=False, separators=(",", ":"))


def camera_json():
    return json.dumps({
        "data": {"BasicInfoToggle": "1",
                 "camera": {"front_camera": FRONT_CAMERA, "rear_camera": REAR_CAMERA}},
        "status": "true",
    }, ensure_ascii=False, separators=(",", ":"))


def smali_str(s):
    out = []
    for ch in s:
        if ch in '"\\':
            out.append("\\" + ch)
        elif 0x20 <= ord(ch) < 0x7f:
            out.append(ch)
        else:
            out.append("\\u%04x" % ord(ch))
    return '"' + "".join(out) + '"'


def run(cmd):
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True)


def method_span(s, header_prefix):
    if s.count(header_prefix) != 1:
        raise SystemExit("method not found exactly once: " + header_prefix)
    start = s.index(header_prefix)
    end = s.index(".end method", start)
    return start, end


def param_regs(header):
    """Registers taken by the parameters (incl. this) of a .method line."""
    desc = re.search(r"\((.*?)\)", header).group(1)
    n = 0 if " static " in header else 1
    i = 0
    while i < len(desc):
        c = desc[i]
        if c in "JD":
            n += 2
        elif c == "L":
            i = desc.index(";", i)
            n += 1
        elif c == "[":
            while desc[i] == "[":
                i += 1
            if desc[i] == "L":
                i = desc.index(";", i)
            n += 1
        else:
            n += 1
        i += 1
    return n


def return_string(s, header_prefix, value):
    start, end = method_span(s, header_prefix)
    header = s[start:s.index("\n", start)]
    body = ("%s\n    .registers %d\n\n    # RMX5010: real device specs (was Sense DeviceParamsHooks)\n"
            "    const-string v0, %s\n\n    return-object v0\n"
            % (header, 1 + param_regs(header), smali_str(value)))
    return s[:start] + body + s[end:]


def patch_features(s):
    start, end = method_span(s, ".method public static isSupportSettingsHaptic(Landroid/content/Context;)Z")
    body = s[start:end]
    old = "    const/4 v0, 0x0\n"
    if old not in body:
        raise SystemExit("isSupportSettingsHaptic: const/4 v0, 0x0 not found")
    i = body.index(old)
    body = body[:i] + "    # RMX5010: haptic settings page supported\n    const/4 v0, 0x1\n" + body[i + len(old):]
    return s[:start] + body + s[end:]


def patch_params(s):
    s = return_string(s, ".method public getBasicParams()Ljava/lang/String;", basic_json())
    return return_string(s, ".method public getCameraParams()Ljava/lang/String;", camera_json())


def patch_cache(s):
    s = return_string(s, ".method public static readBasicInfo(Landroid/content/Context;)Ljava/lang/String;",
                      basic_json())
    return return_string(s, ".method public static readCameraInfo(Landroid/content/Context;)Ljava/lang/String;",
                         camera_json())


def patch_about(s):
    return return_string(s, ".method public static getDeviceMarketName()Ljava/lang/String;", MARKET_NAME)


def patch_face(s):
    start, end = method_span(s, ".method private initProgressView()V")
    body = s[start:end]
    if "RMX5010" in body:
        raise SystemExit("initProgressView already patched")
    anchor = "    invoke-virtual {v0, v2}, %s->setAnimation(I)V\n" % LOTTIE
    if body.count(anchor) != 1:
        raise SystemExit("initProgressView: circle 0 setAnimation anchor not found exactly once")
    # v0 = circle 0 (LottieAnimationView); v2 is reloaded right after.
    add = ("\n    # RMX5010: circle 0 gets the same listener as circles 1..n (was Sense FaceEnrollHooks)\n"
           "    new-instance v2, %s$15;\n\n"
           "    invoke-direct {v2, p0}, %s$15;-><init>(%s)V\n\n"
           "    invoke-virtual {v0, v2}, %s->addAnimatorListener(Landroid/animation/Animator$AnimatorListener;)V\n"
           % (FACE_CLS[:-1], FACE_CLS[:-1], FACE_CLS, LOTTIE))
    i = body.index(anchor) + len(anchor)
    body = body[:i] + add + body[i:]
    return s[:start] + body + s[end:]


PATCHES = ((FEATURES, patch_features), (PARAMS, patch_params), (CACHE, patch_cache),
           (ABOUT, patch_about), (FACE, patch_face))


def main(src, out):
    work = tempfile.mkdtemp(prefix="settings_")
    wanted = {"L" + rel[:-len(".smali")] + ";": rel for rel, _ in PATCHES}
    owner = {}
    with zipfile.ZipFile(src) as z:
        dexes = sorted(n for n in z.namelist() if re.fullmatch(r"classes\d*\.dex", n))
        for name in dexes:
            data = z.read(name)
            if not any(c.encode() in data for c in wanted):
                continue
            path = os.path.join(work, name)
            with open(path, "wb") as f:
                f.write(data)
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

    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(out, "w") as zout:
        for zi in zin.infolist():
            data = open(new_dex[zi.filename], "rb").read() if zi.filename in new_dex \
                else zin.read(zi.filename)
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
    main(sys.argv[1], sys.argv[2])
