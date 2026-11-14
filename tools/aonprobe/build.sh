#!/bin/bash
# Build the Oplus AON HAL probe (root tool, run with app_process).
#
#   bash tools/aonprobe/build.sh
#   adb push tools/aonprobe/out/classes.dex /data/local/tmp/aonprobe.dex
#   adb shell su -c 'app_process -cp /data/local/tmp/aonprobe.dex / AonProbe 4 10'
#
# Arguments: serviceType (default 4 = gaze), seconds (default 25), sensorId (default first).
set -e
cd "$(dirname "$0")"
JAVA_HOME=${JAVA_HOME:-C:/Users/Administrator/.gradle/jdks/eclipse_adoptium-17-amd64-windows.2}
SDK=${ANDROID_SDK:-D:/AndroidSDK}
JAR="$SDK/platforms/android-37.0/android.jar"
export JAVA_HOME
rm -rf classes out && mkdir -p classes out
"$JAVA_HOME/bin/javac" -source 8 -target 8 -cp "$JAR" -d classes AonProbe.java
"$SDK/build-tools/36.0.0/d8.bat" --release --min-api 30 --lib "$JAR" --output out classes/*.class
ls -la out/classes.dex
