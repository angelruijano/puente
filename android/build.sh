#!/bin/bash
# Compila Puente para Android sin Gradle: javac + d8 + aapt2 + apksigner.
set -euo pipefail
cd "$(dirname "$0")"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)"
JAR="$SDK/platforms/android-36/android.jar"
[ -d "$BT" ] && [ -f "$JAR" ] || { echo "Falta el Android SDK (build-tools y platforms;android-36) en $SDK. Ver README."; exit 1; }
if [ -z "${JAVA_HOME:-}" ]; then
    for j in /opt/homebrew/opt/openjdk@17 /usr/local/opt/openjdk@17 "$(/usr/libexec/java_home -v 17 2>/dev/null || true)"; do
        [ -x "$j/bin/javac" ] && export JAVA_HOME="$j" && break
    done
fi
[ -x "${JAVA_HOME:-}/bin/javac" ] || { echo "Falta Java 17 (brew install openjdk@17)."; exit 1; }
export PATH="$JAVA_HOME/bin:$PATH"
rm -rf build && mkdir -p build/classes build/dex
"$BT/aapt2" compile --dir res -o build/res.zip
"$BT/aapt2" link -I "$JAR" --manifest AndroidManifest.xml -o build/base.apk build/res.zip --auto-add-overlay
javac -source 17 -target 17 -encoding UTF-8 -Xlint:-options -classpath "$JAR" -d build/classes $(find src -name '*.java')
"$BT/d8" --release --min-api 30 --lib "$JAR" --output build/dex $(find build/classes -name '*.class')
cp build/base.apk build/unsigned.apk
(cd build/dex && zip -q -j ../unsigned.apk classes.dex)
"$BT/zipalign" -f -p 4 build/unsigned.apk build/aligned.apk
# Llave de firma local, creada en tu Mac la primera vez (nunca va al repositorio)
KS="${PUENTE_KEYSTORE:-$HOME/Library/Application Support/Puente/puente.keystore}"
mkdir -p "$(dirname "$KS")"
[ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storepass puente -keypass puente -alias puente \
    -keyalg RSA -keysize 2048 -validity 36500 -dname "CN=Puente" >/dev/null 2>&1
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:puente --key-pass pass:puente --out build/Puente.apk build/aligned.apk
echo "OK: $(pwd)/build/Puente.apk"
