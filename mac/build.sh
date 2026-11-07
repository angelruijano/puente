#!/bin/bash
# Compila Puente.app (barra de menú) y la instala en ~/Applications.
#   ./build.sh            compila e instala
#   ./build.sh --no-install  solo compila (queda en ~/Library/Caches/Puente-build)
set -euo pipefail
cd "$(dirname "$0")"
BUILD="${PUENTE_BUILD_DIR:-$HOME/Library/Caches/Puente-build}"; APP="$BUILD/Puente.app"
rm -rf "$BUILD" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -framework AppKit -framework CoreAudio -framework AudioToolbox -framework CoreBluetooth -framework Intents -framework UserNotifications \
    -o "$APP/Contents/MacOS/Puente" Sources/*.swift
# Lector de "Ahora suena" (se carga dentro de /usr/bin/perl)
clang -dynamiclib -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 -framework Foundation -framework AppKit \
    -o "$APP/Contents/Resources/nowplaying.dylib" NowPlaying/nowplaying.m
cp NowPlaying/run.pl "$APP/Contents/Resources/nowplaying.pl"
# Atajos de Concentración: se firman en cada Mac (la firma lleva tu cuenta de iCloud, por eso no van en el repo)
for f in on off; do
    shortcuts sign --mode anyone --input "Shortcuts/$f.wflow" --output "$APP/Contents/Resources/$f.shortcut" 2>/dev/null \
        || echo "Aviso: no pude firmar el atajo $f (la sincronización de Concentración no se podrá instalar)."
done
# Ícono
swiftc -O -o "$BUILD/make-icon" Icon/make-icon.swift
"$BUILD/make-icon" "$BUILD/Puente.iconset" && iconutil -c icns -o "$APP/Contents/Resources/Puente.icns" "$BUILD/Puente.iconset"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>cl.hazlo.puente</string>
  <key>CFBundleName</key><string>Puente</string>
  <key>CFBundleDisplayName</key><string>Puente</string>
  <key>CFBundleExecutable</key><string>Puente</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Puente se conecta con tu celular en tu red Wi‑Fi.</string>
  <key>NSBonjourServices</key>
  <array><string>_adb-tls-connect._tcp</string></array>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Enviar al celular</string></dict>
      <key>NSMessage</key><string>sendToPhone</string>
      <key>NSPortName</key><string>Puente</string>
      <key>NSRequiredContext</key><dict/>
      <key>NSSendFileTypes</key><array><string>public.item</string></array>
    </dict>
  </array>
  <key>CFBundleIconFile</key><string>Puente</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Puente usa Bluetooth para saber si tu celular está cerca y para encender su hotspot.</string>
  <key>NSAppleEventsUsageDescription</key><string>Puente lee la pestaña que estás viendo para abrirla en tu celular.</string>
  <key>NSFocusStatusUsageDescription</key><string>Puente activa No molestar en tu celular cuando lo activas en el Mac.</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Llamar y escribir con el celular</string>
    <key>CFBundleURLSchemes</key><array><string>tel</string><string>sms</string><string>telprompt</string><string>callto</string><string>puente</string></array>
  </dict></array>
  <key>NSHumanReadableCopyright</key><string>© 2026 Ángel Ruijano · Licencia MIT</string>
</dict></plist>
PLIST
xattr -cr "$APP"; codesign --force --sign - "$APP/Contents/Resources/nowplaying.dylib"; codesign --force --sign - "$APP"
if [ "${1:-}" = "--no-install" ]; then echo "OK: $APP"; exit 0; fi
mkdir -p ~/Applications
osascript -e 'quit app "Puente"' 2>/dev/null || true
rm -rf ~/Applications/Puente.app && cp -R "$APP" ~/Applications/
echo "OK: ~/Applications/Puente.app"
