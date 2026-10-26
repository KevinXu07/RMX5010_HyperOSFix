#!/usr/bin/env bash
# 用 Android SDK build-tools 直接构建 LSPosed 模块 APK（无需 Gradle/网络）
# 依赖：JDK(javac/jar/keytool)、build-tools 的 aapt2/d8/zipalign、platforms/android-37.0/android.jar
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="${SDK:-/d/AndroidSDK}"
BT="$SDK/build-tools/36.0.0"
AJAR="$SDK/platforms/android-37.0/android.jar"
JAVA_HOME="${JAVA_HOME:-/d/Program Files/Android/Android Studio/jbr}"
JAVAC="$JAVA_HOME/bin/javac"
JAR="$JAVA_HOME/bin/jar"
KEYTOOL="$JAVA_HOME/bin/keytool"
JH_W="$(cygpath -w "$JAVA_HOME")"

OUT="$ROOT/build"
rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/stub" "$OUT/dex"

win() { cygpath -w "$1"; }

echo "== [1] 编译 Xposed API stub =="
find "$ROOT/xposed-api-stub" -name '*.java' | while read -r f; do win "$f"; done > "$OUT/stub_sources.txt"
"$JAVAC" -nowarn -encoding UTF-8 -source 8 -target 8 -d "$OUT/stub" @"$OUT/stub_sources.txt"
"$JAR" cf "$OUT/xposed-api-stub.jar" -C "$OUT/stub" .

echo "== [2] 编译模块代码 =="
find "$ROOT/java" -name '*.java' | while read -r f; do win "$f"; done > "$OUT/sources.txt"
"$JAVAC" -encoding UTF-8 -source 17 -target 17 -Xlint:-options \
  -cp "$(win "$AJAR");$(win "$OUT/xposed-api-stub.jar")" \
  -d "$OUT/classes" @"$OUT/sources.txt" 2>&1 | tail -30

echo "== [3] aapt2 资源 =="
"$BT/aapt2.exe" compile --dir "$ROOT/res" -o "$OUT/res.zip"
"$BT/aapt2.exe" link -o "$OUT/base.apk" -I "$(win "$AJAR")" \
  --manifest "$(win "$ROOT/AndroidManifest.xml")" -R "$(win "$OUT/res.zip")" \
  --min-sdk-version 35 --target-sdk-version 37 \
  --version-code 1 --version-name 1.0.0 --auto-add-overlay

echo "== [4] d8 转 dex =="
find "$OUT/classes" -name '*.class' | while read -r f; do win "$f"; done > "$OUT/classfiles.txt"
D8ARGS=()
while IFS= read -r f; do D8ARGS+=("$f"); done < "$OUT/classfiles.txt"
JAVA_HOME="$JH_W" "$BT/d8.bat" --release --min-api 35 --lib "$(win "$AJAR")" \
  --output "$(win "$OUT/dex")" "${D8ARGS[@]}"

echo "== [5] 组装 APK =="
cp "$OUT/base.apk" "$OUT/unsigned.apk"
python - "$OUT/unsigned.apk" "$OUT/dex/classes.dex" "$ROOT/assets/xposed_init" "$ROOT" <<'PY'
import sys, zipfile, shutil
from pathlib import Path
apk, dex, init, root = sys.argv[1:5]
root = Path(root)
tmp = apk + ".tmp"
with zipfile.ZipFile(apk) as zin, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        zout.writestr(item, zin.read(item.filename))
    zout.write(dex, "classes.dex")
    zout.write(init, "assets/xposed_init")
    libs = root / "libs" / "arm64-v8a"
    if libs.is_dir():
        for lib in sorted(libs.glob("*.so")):
            zout.write(lib, "lib/arm64-v8a/" + lib.name)
shutil.move(tmp, apk)
print("apk assembled")
PY

echo "== [6] 对齐 + 签名 =="
"$BT/zipalign.exe" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
KS="$ROOT/debug.keystore"
if [ ! -f "$KS" ]; then
  "$KEYTOOL" -genkeypair -v -keystore "$KS" -alias androiddebugkey \
    -storepass android -keypass android -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1
fi
JAVA_HOME="$JH_W" "$BT/apksigner.bat" sign --ks "$(win "$KS")" --ks-pass pass:android \
  --key-pass pass:android --out "$(win "$ROOT/RMX5010_HyperOSFix_lsposed.apk")" "$(win "$OUT/aligned.apk")"
JAVA_HOME="$JH_W" "$BT/apksigner.bat" verify --print-certs "$(win "$ROOT/RMX5010_HyperOSFix_lsposed.apk")" | head -4
ls -la "$ROOT/RMX5010_HyperOSFix_lsposed.apk"
echo BUILD_APK_DONE
