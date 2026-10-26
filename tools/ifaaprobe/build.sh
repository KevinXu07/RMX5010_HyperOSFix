set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
BT="${SDK:-/d/AndroidSDK}/build-tools/36.0.0"
JAVA_HOME="/d/Program Files/Android/Android Studio/jbr"
JAVA="$JAVA_HOME/bin/java.exe"
JAVAC="$JAVA_HOME/bin/javac.exe"
ANDROID_JAR="${SDK:-/d/AndroidSDK}/platforms/android-37.0/android.jar"

rm -rf "$ROOT/classes" "$ROOT/dex" "$ROOT/gen"
mkdir -p "$ROOT/classes" "$ROOT/dex" "$ROOT/gen"

"$BT/aapt2.exe" link -o "$ROOT/unsigned.apk" -I "$ANDROID_JAR" \
  --manifest "$ROOT/AndroidManifest.xml" --java "$ROOT/gen"

find "$ROOT/src" "$ROOT/gen" -name '*.java' | while IFS= read -r f; do cygpath -w "$f"; done > "$ROOT/sources.txt"
"$JAVAC" --release 11 -classpath "$ANDROID_JAR" -d "$ROOT/classes" @"$ROOT/sources.txt"

"$JAVA" -cp "$BT/lib/d8.jar" com.android.tools.r8.D8 \
  --min-api 29 --lib "$ANDROID_JAR" --output "$ROOT/dex" \
  $(find "$ROOT/classes" -name '*.class')

python - "$ROOT/unsigned.apk" "$ROOT/dex/classes.dex" <<'PY'
import sys, zipfile
apk, dex = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(apk, 'a', zipfile.ZIP_DEFLATED) as z:
    z.write(dex, 'classes.dex')
PY

"$BT/zipalign.exe" -f 4 "$ROOT/unsigned.apk" "$ROOT/aligned.apk"
"$JAVA" -jar "$BT/lib/apksigner.jar" sign \
  --ks "$HOME/.android/debug.keystore" --ks-pass pass:android --key-pass pass:android \
  --out "$ROOT/ifaaprobe.apk" "$ROOT/aligned.apk"
"$BT/zipalign.exe" -c 4 "$ROOT/ifaaprobe.apk"
ls -l "$ROOT/ifaaprobe.apk"
