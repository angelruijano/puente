package cl.hazlo.puente.shell;

import android.content.ClipData;
import android.content.ClipDescription;
import android.net.Uri;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.util.Base64;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Ayudante que corre como usuario "shell" (lanzado por el Mac con adb + app_process).
 * Android permite a shell leer el portapapeles en segundo plano, cosa que una app normal no puede.
 *
 * Protocolo: una línea JSON por mensaje.
 *   stdout → Mac:  {"t":"hello"} {"t":"text","d":...} {"t":"image","mime":...,"b64":...} {"t":"battery","level":n,"charging":b} {"t":"log","d":...}
 *   stdin  ← Mac:  {"t":"text","d":...} {"t":"ping"}
 *   Música: el Mac manda {"t":"np",...} y {"t":"vol","v":n}; se reenvían a MediaService (app) por un
 *   socket local con token. La app responde {"t":"media","c":...} / {"t":"setvol","v":n}, que van al Mac.
 */
public final class Helper {
    private static final String PKG = "com.android.shell";
    private static final String OWN_AUTHORITY = "cl.hazlo.puente.clip";
    private static final int MAX_IMAGE = 25 * 1024 * 1024;

    private static PrintStream out;
    private static Object clipboard;
    private static final ExecutorService worker = Executors.newSingleThreadExecutor();
    private static volatile String lastTextFromMac;
    private static volatile String lastSentKey;

    public static void main(String[] args) throws Exception {
        out = new PrintStream(new FileOutputStream(FileDescriptor.out), true, "UTF-8");
        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, "clipboard");
        clipboard = Class.forName("android.content.IClipboard$Stub")
                .getMethod("asInterface", IBinder.class).invoke(null, binder);

        registerListener();
        send(new JSONObject().put("t", "hello").put("v", 2).put("ip", NetLink.wifiAddress()).put("name", deviceName()));
        startBattery();
        MediaRelay.start(Helper::send, Helper::log);
        startHotspotSupport();
        Photos.start(Helper::send, Helper::log);

        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        String line;
        startMacWatchdog();
        while ((line = in.readLine()) != null) {
            lastFromMac = System.currentTimeMillis();
            try {
                JSONObject m = new JSONObject(line);
                switch (m.optString("t")) {
                    case "text":
                        String d = m.getString("d");
                        lastTextFromMac = d;
                        ClipData nc = ClipData.newPlainText("Puente", d);
                        if (m.optBoolean("sensitive")) {
                            android.os.PersistableBundle ex = new android.os.PersistableBundle();
                            ex.putBoolean("android.content.extra.IS_SENSITIVE", true);
                            nc.getDescription().setExtras(ex);
                        }
                        call("setPrimaryClip", nc);
                        break;
                    case "debugUri": // prueba: simula copiar una imagen de otra app
                        call("setPrimaryClip", new ClipData(new ClipDescription("t", new String[]{m.getString("mime")}),
                                new ClipData.Item(Uri.parse(m.getString("uri")))));
                        break;
                    case "peek": { // diagnóstico: qué hay ahora en el portapapeles
                        ClipData c = (ClipData) call("getPrimaryClip");
                        JSONObject r = new JSONObject().put("t", "peek");
                        if (c != null && c.getItemCount() > 0) {
                            r.put("mime", c.getDescription().getMimeType(0));
                            ClipData.Item it = c.getItemAt(0);
                            if (it.getText() != null) r.put("text", it.getText().toString());
                            if (it.getUri() != null) r.put("uri", it.getUri().toString());
                        }
                        send(r);
                        break;
                    }
                    case "np":
                    case "vol":
                        MediaRelay.fromMac(m);
                        break;
                    case "notifAction":
                    case "notifDismiss":
                    case "ring":
                    case "ringStop":
                    case "dnd":
                    case "smsSend":
                    case "sims":
                    case "smsThreads":
                    case "smsThread":
                        MediaRelay.toNotif(m);
                        break;
                    case "adbWifi": // el Mac pide (o suelta) la depuración inalámbrica: la app decide según la red
                        MediaRelay.toNotif(m);
                        break;
                    case "frm":
                    case "clipImage":
                        NetFiles.handle(m);
                        break;
                    case "fileIn": { // el Mac dejó archivos en Descargas: indexarlos y avisar
                        org.json.JSONArray paths = m.optJSONArray("paths");
                        worker.execute(() -> {
                            if (paths != null && !m.optBoolean("scanned")) for (int k = 0; k < paths.length(); k++) {
                                String path = paths.optString(k);
                                if (path.startsWith("/sdcard/Download/"))
                                    run("am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE", "-d", "file://" + Uri.encode(path, "/"));
                            }
                            MediaRelay.toNotif(m);
                        });
                        break;
                    }
                    case "dial": { // llamar desde el Mac: el celular marca
                        String num = m.optString("number").replaceAll("[^0-9+*#,;]", "");
                        if (!num.isEmpty()) run("am", "start", "-a", "android.intent.action.CALL",
                                "-d", "tel:" + Uri.encode(num, "+,;"));
                        break;
                    }
                    case "openUrl": { // pestaña del Mac → celular
                        String url = m.optString("url");
                        if (url.startsWith("http://") || url.startsWith("https://"))
                            run("am", "start", "-a", "android.intent.action.VIEW", "-d", url);
                        break;
                    }
                    case "contacts":
                        worker.execute(Helper::sendContacts);
                        break;
                    case "photos":
                        Photos.enabled = m.optBoolean("on", true);
                        break;
                    case "bleKey":
                        MediaRelay.setConfig("bleKey", m.getString("k"));
                        break;
                    case "ping":
                        send(new JSONObject().put("t", "pong"));
                        break;
                }
            } catch (Throwable e) {
                log("cmd error: " + e);
            }
        }
        System.exit(0); // el Mac cerró la conexión
    }

    // ---------- portapapeles ----------

    private static void registerListener() throws Exception {
        final Binder callback = new Binder() {
            @Override
            protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
                if (code == IBinder.FIRST_CALL_TRANSACTION) { // dispatchPrimaryClipChanged (oneway)
                    worker.execute(Helper::onClipChanged);
                    return true;
                }
                try { return super.onTransact(code, data, reply, flags); } catch (Exception e) { return false; }
            }
        };
        Class<?> iface = Class.forName("android.content.IOnPrimaryClipChangedListener");
        Object listener = Proxy.newProxyInstance(iface.getClassLoader(), new Class<?>[]{iface}, (p, m, a) -> {
            switch (m.getName()) {
                case "asBinder": return callback;
                case "dispatchPrimaryClipChanged": worker.execute(Helper::onClipChanged); return null;
                case "hashCode": return System.identityHashCode(p);
                case "equals": return p == a[0];
                case "toString": return "PuenteListener";
            }
            return null;
        });
        call("addPrimaryClipChangedListener", listener);
    }

    private static void onClipChanged() {
        try {
            // A veces Android devuelve vacío justo después del cambio: reintentar un poco
            ClipData clip = null;
            for (int i = 0; i < 5 && (clip == null || clip.getItemCount() == 0); i++) {
                if (i > 0) Thread.sleep(120L * i);
                clip = (ClipData) call("getPrimaryClip");
            }
            if (clip == null || clip.getItemCount() == 0) { log("portapapeles vacío tras el cambio"); return; }
            ClipData.Item item = clip.getItemAt(0);
            ClipDescription desc = clip.getDescription();

            Uri uri = item.getUri();
            String mime = null;
            if (desc != null) for (int i = 0; i < desc.getMimeTypeCount(); i++) {
                if (desc.getMimeType(i).startsWith("image/")) { mime = desc.getMimeType(i); break; }
            }
            if (uri != null && mime != null) {
                if (OWN_AUTHORITY.equals(uri.getAuthority())) return; // vino del Mac
                byte[] bytes = readUri(uri);
                if (bytes == null || bytes.length == 0) { log("no pude leer imagen " + uri); return; }
                String key = "img:" + bytes.length + ":" + java.util.Arrays.hashCode(bytes);
                if (key.equals(lastSentKey)) return;
                lastSentKey = key;
                send(new JSONObject().put("t", "image").put("mime", mime)
                        .put("b64", Base64.encodeToString(bytes, Base64.NO_WRAP)));
                return;
            }

            CharSequence cs = item.getText();
            if (cs == null && item.getHtmlText() != null) cs = item.getHtmlText();
            if (cs == null) return;
            String text = cs.toString();
            if (text.equals(lastTextFromMac)) return; // eco de lo que mandó el Mac
            String key = "txt:" + text.hashCode() + ":" + text.length();
            if (key.equals(lastSentKey)) return;
            lastSentKey = key;
            boolean sensitive = desc != null && desc.getExtras() != null
                    && desc.getExtras().getBoolean("android.content.extra.IS_SENSITIVE", false);
            send(new JSONObject().put("t", "text").put("d", text).put("sensitive", sensitive));
        } catch (Throwable e) {
            log("clip error: " + e);
        }
    }

    /** Lee un content:// como shell (el portapapeles concede el permiso de lectura a quien lo lee). */
    private static byte[] readUri(Uri uri) {
        try {
            Process p = new ProcessBuilder("content", "read", "--uri", uri.toString()).start();
            p.getOutputStream().close();
            try (InputStream is = p.getInputStream()) {
                ByteArrayOutputStream bos = new ByteArrayOutputStream();
                byte[] buf = new byte[65536];
                int n;
                while ((n = is.read(buf)) > 0) {
                    bos.write(buf, 0, n);
                    if (bos.size() > MAX_IMAGE) { p.destroy(); return null; }
                }
                p.waitFor();
                return bos.toByteArray();
            }
        } catch (Exception e) {
            log("readUri: " + e);
            return null;
        }
    }

    /** Llama un método de IClipboard rellenando los argumentos según la firma de esta versión de Android. */
    private static Object call(String name, Object... given) throws Exception {
        for (Method m : clipboard.getClass().getMethods()) {
            if (!m.getName().equals(name)) continue;
            Class<?>[] types = m.getParameterTypes();
            Object[] args = new Object[types.length];
            int g = 0, strings = 0;
            for (int i = 0; i < types.length; i++) {
                Class<?> t = types[i];
                if (g < given.length && given[g] != null && t.isInstance(given[g])) { args[i] = given[g++]; }
                else if (t == String.class) { args[i] = (strings++ == 0) ? PKG : null; }
                else if (t == int.class) { args[i] = 0; } // userId 0, deviceId 0 (DEFAULT)
                else if (t == boolean.class) { args[i] = false; }
                else { args[i] = null; }
            }
            return m.invoke(clipboard, args);
        }
        throw new NoSuchMethodException(name);
    }

    // ---------- utilidades ----------

    static void run(String... cmd) {
        try {
            Process p = new ProcessBuilder(cmd).redirectErrorStream(true).start();
            p.getOutputStream().close();
            p.getInputStream().readAllBytes();
            p.waitFor();
        } catch (Exception e) { log("run " + cmd[0] + ": " + e); }
    }

    /** Contactos con teléfono, para autocompletar en el Mac al escribir un SMS. */
    private static void sendContacts() {
        try {
            Process p = new ProcessBuilder("content", "query", "--uri", "content://com.android.contacts/data/phones",
                    "--projection", "display_name:data1").redirectErrorStream(true).start();
            p.getOutputStream().close();
            org.json.JSONArray list = new org.json.JSONArray();
            java.util.Set<String> seen = new java.util.HashSet<>();
            try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8))) {
                String l;
                while ((l = r.readLine()) != null) {
                    int a = l.indexOf("display_name="), b = l.lastIndexOf(", data1=");
                    if (a < 0 || b < a) continue;
                    String name = l.substring(a + 13, b).trim(), num = l.substring(b + 8).trim();
                    String norm = num.replaceAll("[^0-9+]", "");
                    if (norm.length() < 5 || !seen.add(name + norm)) continue;
                    list.put(new org.json.JSONArray().put(name).put(num));
                }
            }
            p.waitFor();
            send(new JSONObject().put("t", "contacts").put("list", list));
        } catch (Exception e) { log("contacts: " + e); }
    }

    // ---------- Mac en silencio ----------

    private static volatile long lastFromMac = System.currentTimeMillis();

    /**
     * El Mac manda un latido cada 15 s. Si se calla (tapa cerrada sin aviso, Wi‑Fi caído),
     * quitar el reproductor del celular: no tiene sentido controlar algo que no suena.
     */
    private static void startMacWatchdog() {
        Thread t = new Thread(() -> {
            boolean hidden = false;
            while (true) {
                try { Thread.sleep(10000); } catch (InterruptedException e) { return; }
                boolean silent = System.currentTimeMillis() - lastFromMac > 45000;
                if (silent && !hidden) {
                    try { MediaRelay.fromMac(new JSONObject().put("t", "np").put("none", true)); } catch (Exception ignored) {}
                    hidden = true;
                } else if (!silent) {
                    hidden = false;
                }
            }
        }, "mac-watchdog");
        t.setDaemon(true);
        t.start();
    }

    /** Nombre del celular (Ajustes › Acerca del teléfono), o fabricante y modelo. */
    private static String deviceName() {
        try {
            Process p = new ProcessBuilder("settings", "get", "global", "device_name").redirectErrorStream(true).start();
            String n = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8).trim();
            p.waitFor();
            if (!n.isEmpty() && !n.equals("null")) return n;
        } catch (Exception ignored) {}
        return android.os.Build.MANUFACTURER + " " + android.os.Build.MODEL;
    }

    // ---------- hotspot ----------

    /** Lanza el residente (sobrevive sin Mac) y le pasa al Mac los datos del hotspot para conectarse. */
    private static void startHotspotSupport() {
        Thread t = new Thread(() -> {
            try {
                String token = Daemon.ensure(System.getProperty("java.class.path"));
                if (token == null) { log("hotspot: no pude lanzar el residente"); return; }
                MediaRelay.setConfig("daemonPort", Daemon.PORT);
                MediaRelay.setConfig("daemonToken", token);
                String[] c = Tether.credentials();
                send(new JSONObject().put("t", "hotspotCreds").put("ssid", c[0]).put("pass", c[1]));
            } catch (Throwable e) {
                log("hotspot: " + e);
            }
        }, "hotspot");
        t.setDaemon(true);
        t.start();
    }

    // ---------- batería ----------

    private static void startBattery() {
        Thread t = new Thread(() -> {
            String last = "";
            while (true) {
                try {
                    int level = -1, status = 0;
                    Process p = new ProcessBuilder("dumpsys", "battery").start();
                    try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()))) {
                        String l;
                        while ((l = r.readLine()) != null) {
                            l = l.trim();
                            if (l.startsWith("level:")) level = Integer.parseInt(l.substring(6).trim());
                            else if (l.startsWith("status:")) status = Integer.parseInt(l.substring(7).trim());
                        }
                    }
                    p.waitFor();
                    if (level < 0) throw new IllegalStateException("sin nivel");
                    boolean charging = status == 2 || status == 5; // CHARGING / FULL
                    String now = level + ":" + charging;
                    if (!now.equals(last)) {
                        last = now;
                        send(new JSONObject().put("t", "battery").put("level", level).put("charging", charging));
                    }
                } catch (Throwable e) {
                    log("battery: " + e);
                    try { Thread.sleep(300000); } catch (InterruptedException ignored) {}
                }
                try { Thread.sleep(20000); } catch (InterruptedException ignored) {}
            }
        }, "battery");
        t.setDaemon(true);
        t.start();
    }

    // ---------- salida ----------

    static synchronized void send(JSONObject o) {
        out.println(o.toString());
        if (out.checkError()) System.exit(0);
    }

    private static void log(String s) {
        try { send(new JSONObject().put("t", "log").put("d", s)); } catch (Exception ignored) {}
    }
}
