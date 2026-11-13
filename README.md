# Puente

**Tu Android y tu Mac, conectados como un iPhone.** Puente es una app de barra de menú para macOS y una app para Android que juntas dan casi toda la "continuidad" de Apple: portapapeles compartido, notificaciones, códigos SMS, mensajes, llamadas, música, archivos tipo AirDrop, hotspot instantáneo y bloqueo por proximidad.

Sin nube, sin cuentas y sin servidores de terceros: todo va directo entre tus dos equipos, cifrado.

> Proyecto personal, probado en un **Nothing Phone 2 (Android 16)** con un **MacBook Pro M1 (macOS 27)**. Debería andar en otros Android 11+ y Macs con Apple Silicon, pero no está garantizado.

## Qué hace

| | |
|---|---|
| 📋 **Portapapeles universal** | Copias en uno y pegas en el otro: texto e imágenes, en ambos sentidos. |
| 🔔 **Notificaciones** | Las del celular aparecen en el Mac. Puedes responder y descartarlas, y se sincroniza en ambos sentidos. WhatsApp y Telegram quedan excluidos por defecto porque ya tienen app para Mac. |
| 🔑 **Códigos SMS** | Los códigos de verificación se copian solos al portapapeles del Mac. |
| 💬 **Mensajes** | Ventana estilo Mensajes para leer y enviar SMS desde el Mac, con selector de SIM. |
| 📞 **Llamadas** | Avisos de llamada en el Mac. Los enlaces `tel:` y `sms:` del Mac se abren en el celular. |
| 🎵 **Música** | El celular controla lo que suena en el Mac (YouTube en el navegador, IINA, VLC…) como si fuera un parlante Bluetooth: notificación multimedia, pantalla de bloqueo y volumen. |
| 📁 **Archivos tipo AirDrop** | Arrastra archivos o carpetas al ícono de la barra de menú, o usa «Compartir → Enviar al Mac» en el celular. |
| 📱 **Pantalla** | Ve y controla el celular desde el Mac (usa [scrcpy](https://github.com/Genymobile/scrcpy)). |
| 📶 **Hotspot instantáneo** | Enciende el hotspot del celular desde el Mac por Bluetooth, sin tocarlo. |
| 📡 **Hotspot automático** | Si el Mac se queda sin Wi‑Fi y el celular está cerca, enciende el hotspot y se conecta solo. Al llegar a casa lo apaga para no gastar datos. |
| 🔒 **Bloqueo por proximidad** | El Mac se bloquea cuando te alejas con el celular. Nunca se desbloquea solo. |
| 🔍 **Buscar mi celular** | Lo hace sonar, vibrar y prender el flash (y las luces Glyph en un Nothing). |
| 🌙 **No molestar** | Sincronizado entre el Mac y el celular. |
| 🎙️ **Silencio en reuniones** | Cuando usas el micrófono del Mac (Meet, Zoom, Teams…), el celular entra en No molestar, y vuelve a la normalidad al cortar. |
| 🔋 **Batería** | La batería del celular, en la barra de menú. |
| ↗️ **Abrir en el otro** | Comparte una página del celular al Mac (YouTube sigue en el mismo minuto), o la pestaña del Mac al celular. |

## Requisitos

- **Mac con Apple Silicon** y macOS 14 o superior, con las herramientas de Xcode: `xcode-select --install`.
- **Celular Android 11 o superior** con las [opciones de desarrollador](https://developer.android.com/studio/debug/dev-options) activadas y la **depuración USB** encendida.
- Un **cable USB** para la primera instalación.
- **Java 17** y el **Android SDK** (solo para compilar). Con [Homebrew](https://brew.sh):

  ```bash
  brew install openjdk@17 scrcpy
  brew install --cask android-commandlinetools
  sdkmanager --sdk_root="$HOME/Library/Android/sdk" "platform-tools" "build-tools;36.0.0" "platforms;android-36"
  ```

  También sirve instalar [Android Studio](https://developer.android.com/studio) y, desde su SDK Manager, agregar Android 16 (API 36) y las build-tools.

## Instalación

```bash
git clone https://github.com/ruiangabo/puente.git
cd puente
./install.sh
```

El instalador compila las dos apps, deja **Puente.app** en `~/Applications`, instala la app en el celular por USB, le concede los permisos y abre todo. Después, una sola vez:

1. **En el Mac**, acepta los permisos que pida Puente: Bluetooth, red local y notificaciones. Para la sincronización de No molestar, usa «Añadir atajos…» en el menú.
2. **En el celular**, abre Puente y toca **«Confiar en "tu red"»** estando conectado al Wi‑Fi de tu casa. Solo en esas redes se permite la conexión inalámbrica.
3. **Para usarlo sin cable**: en el celular entra a Opciones de desarrollador → **Depuración inalámbrica**, actívala y vincula el Mac una vez:

   ```bash
   ~/Library/Android/sdk/platform-tools/adb pair IP:PUERTO
   ```

   Ingresa el código que te muestra el celular. A partir de ahí Puente la enciende cuando la necesita y la apaga sola.

Para actualizar: `git pull && ./install.sh`.

## Cómo funciona

- **En el Mac**, una app de barra de menú en Swift y SwiftUI.
- **En el celular** corren dos partes:
  - la app normal (servicios de notificaciones, música y Bluetooth);
  - un **ayudante** que se lanza con el usuario `shell` de Android (`adb shell app_process`). Así puede leer el portapapeles en segundo plano y usar funciones del sistema que una app común no puede, sin root.
- **Conexión:**
  - con cable, por adb;
  - **sin cable, en casa o con el hotspot del celular**, por un canal propio cifrado;
  - por Bluetooth Low Energy para la proximidad, el hotspot y para despertar la conexión.
- **La depuración inalámbrica queda apagada** casi siempre. Puente la enciende solo cuando de verdad la necesita (por ejemplo, para la pantalla), solo en tus redes de confianza y por pocos minutos.

### Seguridad

- **Canal propio:** saludo con llaves efímeras **X25519**, llaves de sesión con **HKDF-SHA256** sobre una llave compartida de 256 bits y **AES-256-GCM** con contador. Tiene *forward secrecy*: aunque se filtrara la llave compartida, las sesiones grabadas no se pueden descifrar.
- **Llaves:** la llave compartida se crea en tu Mac y pasa al celular por adb (por cable, o por la depuración inalámbrica, que también va cifrada). Nunca viaja por el canal propio.
- **Dónde acepta conexiones el celular:** solo direcciones locales, y solo por el hotspot encendido o por el Wi‑Fi de una red que marcaste como de confianza. Nunca por datos móviles ni redes públicas.
- **Bluetooth:** el celular se anuncia con un HMAC que rota cada 15 minutos, así que no se le puede seguir. Los comandos por Bluetooth (hotspot, despertar) van firmados.
- **Secretos en el Mac:** la llave Bluetooth, la llave del canal y los datos del hotspot se guardan en `~/Library/Application Support/Puente/secrets.json` (permisos 600). En el celular viven en `/data/local/tmp/puente`. Ninguno está en este repositorio.
- **Nada sale de tus equipos:** no hay telemetría ni servidores.

## Limitaciones (léelas antes de instalar)

- **La depuración USB tiene que quedar encendida.** Si la apagas, Android cierra el ayudante al instante y Puente deja de funcionar hasta que la vuelvas a encender.
- **APIs ocultas:** usa APIs internas de Android y de macOS (el portapapeles como `shell`, el tethering, MediaRemote). Una actualización del sistema puede romper alguna función.
- **Primera vez:** necesitas cable y, para usarlo sin cable, vincular la depuración inalámbrica una vez.
- **Solo en algunos equipos:** las luces Glyph funcionan solo en teléfonos Nothing. El hotspot instantáneo depende de cada fabricante.
- **macOS no deja que otra app mande SMS desde Mensajes.app**, así que Puente trae su propia ventana de mensajes.
- **Firma local:** la app del Mac se firma localmente, sin cuenta de desarrollador de Apple. Por eso se compila en cada Mac en vez de distribuirse ya compilada.

## Estructura

```
android/   App de Android + ayudante (Java, sin Gradle: javac + d8 + aapt2)
  build.sh
mac/       App de barra de menú (Swift)
  build.sh   ./build.sh --no-install para solo compilar
install.sh Compila e instala todo
```

## Licencia

[MIT](LICENSE) © 2026 Ángel Ruijano. Úsalo, modifícalo y compártelo libremente.

---

### English (short)

**Puente** brings iPhone‑style continuity to Android + Mac, with no cloud: universal clipboard, notifications (reply and dismiss), SMS codes auto‑copied, an SMS window, calls, media controls, AirDrop‑like file transfer, screen mirroring (scrcpy), instant hotspot over BLE (automatic when the Mac loses Wi‑Fi), proximity lock, auto‑DND on the phone during calls on the Mac, Do Not Disturb sync and battery in the menu bar.

The traffic is end‑to‑end encrypted (X25519 + HKDF + AES‑GCM with forward secrecy) and only accepted on trusted home Wi‑Fi or the phone's hotspot. It needs an Apple Silicon Mac, Android 11+ with USB debugging kept on, Java 17 and the Android SDK to build. Run `./install.sh` with the phone plugged in. It was tested on a Nothing Phone 2 (Android 16); it uses hidden APIs, so expect rough edges. The UI is in Spanish. MIT licensed.
