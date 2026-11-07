#!/bin/bash
# Instala Puente: compila la app del Mac y la del celular, instala el APK por USB y concede los permisos.
# Uso: conecta el celular por cable con la depuración USB activada y ejecuta ./install.sh
set -euo pipefail
cd "$(dirname "$0")"
PKG=cl.hazlo.puente
ok()   { printf "\033[32m✓\033[0m %s\n" "$1"; }
fail() { printf "\033[31m✗\033[0m %s\n" "$1"; exit 1; }

echo "== Revisando requisitos"
[ "$(uname -m)" = "arm64" ] || fail "Puente necesita un Mac con Apple Silicon."
command -v swiftc >/dev/null || fail "Faltan las herramientas de Xcode: xcode-select --install"
ok "Xcode Command Line Tools"
ADB=""
for a in "${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb" /opt/homebrew/bin/adb /usr/local/bin/adb; do
    [ -x "$a" ] && ADB="$a" && break
done
[ -n "$ADB" ] || fail "Falta adb. Instala el Android SDK (ver README, sección Requisitos)."
ok "adb ($ADB)"
command -v scrcpy >/dev/null && ok "scrcpy (pantalla del celular en el Mac)" \
    || echo "  · scrcpy no está: la función Pantalla no andará hasta que hagas: brew install scrcpy"

echo "== Compilando"
android/build.sh
mac/build.sh

echo "== Instalando en el celular"
"$ADB" start-server >/dev/null 2>&1 || true
echo "  Conecta el celular por USB y acepta «Permitir depuración USB» si aparece…"
"$ADB" wait-for-usb-device
SERIAL="$("$ADB" devices -l | awk '/ usb:/{print $1; exit}')"
[ -n "$SERIAL" ] || fail "No encontré el celular por USB."
A() { "$ADB" -s "$SERIAL" "$@"; }
A install -r -g android/build/Puente.apk >/dev/null && ok "App instalada"
for p in WRITE_SECURE_SETTINGS SEND_SMS READ_SMS READ_PHONE_STATE ACCESS_FINE_LOCATION \
         ACCESS_BACKGROUND_LOCATION POST_NOTIFICATIONS BLUETOOTH_ADVERTISE BLUETOOTH_CONNECT; do
    A shell pm grant "$PKG" "android.permission.$p" 2>/dev/null || echo "  · no pude conceder $p (puedes darlo a mano en Ajustes)"
done
A shell cmd notification allow_listener "$PKG/.NotifListener" || true
A shell cmd deviceidle whitelist +"$PKG" >/dev/null 2>&1 || true
ok "Permisos concedidos"
A shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1 || true

echo "== Abriendo Puente en el Mac"
open ~/Applications/Puente.app
cat <<MSG

Listo. Pasos que quedan (una sola vez):
  1. En el Mac, acepta los permisos que pida Puente (Bluetooth, red local, notificaciones).
  2. En el celular, abre Puente y toca «Confiar en "tu red"» estando en el Wi‑Fi de tu casa.
  3. Para usarlo sin cable: en el celular, Opciones de desarrollador → Depuración inalámbrica,
     y vincula el Mac una vez (ver README). Después Puente la enciende y apaga solo.
  No desactives la depuración USB: Puente la necesita.
MSG
