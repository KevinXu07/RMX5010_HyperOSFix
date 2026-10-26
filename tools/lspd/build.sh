#!/usr/bin/env bash
# Build the app_process SQLite helpers used to register an LSPosed module and
# add packages to its scope without the manager UI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="${SDK:-/d/AndroidSDK}"
BT="$SDK/build-tools/36.0.0"
AJAR="$SDK/platforms/android-37.0/android.jar"
JAVA_HOME="${JAVA_HOME:-/d/Program Files/Android/Android Studio/jbr}"
JAVAC="$JAVA_HOME/bin/javac"
JAVA="$JAVA_HOME/bin/java"

rm -rf "$ROOT/out"
mkdir -p "$ROOT/out/classes" "$ROOT/out/dex"

"$JAVAC" --release 11 -classpath "$AJAR" -d "$ROOT/out/classes" \
  "$ROOT/src/LspdScope.java" "$ROOT/src/LspdModule.java"

"$JAVA" -cp "$BT/lib/d8.jar" com.android.tools.r8.D8 \
  --min-api 35 --lib "$AJAR" --output "$ROOT/out/dex" \
  "$ROOT/out/classes/LspdScope.class" "$ROOT/out/classes/LspdModule.class"

cp "$ROOT/out/dex/classes.dex" "$ROOT/lspdscope.dex"
ls -l "$ROOT/lspdscope.dex"
