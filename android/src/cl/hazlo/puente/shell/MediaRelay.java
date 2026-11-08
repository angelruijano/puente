package cl.hazlo.puente.shell;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.function.Consumer;

/**
 * Puente entre el Mac y MediaService (la app). Escucha solo en 127.0.0.1 y exige un token aleatorio,
 * que se entrega a la app al arrancar el servicio.
 */
final class MediaRelay {
    private static final String SERVICE = "cl.hazlo.puente/.MediaService";

    private static Consumer<JSONObject> toMac;
    private static Consumer<String> log;
    private static ServerSocket server;
    private static String token;
    private static volatile OutputStream client;      // MediaService
    private static volatile OutputStream notifClient; // NotifListener
    private static final String MESSAGES = "com.google.android.apps.messaging";
    private static volatile JSONObject lastNp, lastNpArt, lastVol;
    private static volatile long lastStart;
    /** Configuración para la app: llave BLE (del Mac) y token del residente (del hotspot). */
    private static final JSONObject config = new JSONObject();

    static void start(Consumer<JSONObject> toMac, Consumer<String> log) {
        MediaRelay.toMac = toMac;
        MediaRelay.log = log;
        byte[] b = new byte[24];
        new SecureRandom().nextBytes(b);
        StringBuilder sb = new StringBuilder();
        for (byte x : b) sb.append(String.format("%02x", x));
        token = sb.toString();
        try {
            server = new ServerSocket(0, 2, InetAddress.getByName("127.0.0.1"));
        } catch (Exception e) {
            log.accept("media: no pude abrir socket: " + e);
            return;
        }
        Thread t = new Thread(MediaRelay::acceptLoop, "media");
        t.setDaemon(true);
        t.start();
        // Avisar a la app dónde estamos (para el lector de notificaciones) y fijar el punto de partida de SMS
        new Thread(() -> {
            Sms.init();
            run("am", "broadcast", "-n", "cl.hazlo.puente/.LinkReceiver",
                    "--ei", "port", String.valueOf(server.getLocalPort()), "--es", "token", token);
        }, "announce").start();
    }

    static void setConfig(String k, Object v) {
        try {
            synchronized (config) { config.put(k, v); }
            sendConfig(notifClient);
        } catch (Exception ignored) {}
    }

    private static void sendConfig(OutputStream c) {
        if (c == null) return;
        try {
            JSONObject m;
            synchronized (config) { m = new JSONObject(config.toString()).put("t", "config"); }
            write(c, m);
        } catch (Exception ignored) {}
    }

    /** Mensajes del Mac para el lector de notificaciones (acciones, descartar). */
    static void toNotif(JSONObject m) {
        OutputStream c = notifClient;
        if (c == null) return;
        try { write(c, m); } catch (Exception e) { notifClient = null; }
    }

    private static void run(String... cmd) {
        try {
            Process p = new ProcessBuilder(cmd).redirectErrorStream(true).start();
            p.getOutputStream().close();
            p.getInputStream().readAllBytes();
            p.waitFor();
        } catch (Exception e) {
            log.accept("run " + cmd[0] + ": " + e);
        }
    }

    /** Notificación de la app: si es de Mensajes, mandar el SMS completo (con el código) en vez de la notificación. */
    private static void onNotif(JSONObject m) throws Exception {
        if ("notif".equals(m.optString("t")) && MESSAGES.equals(m.optString("pkg"))) {
            java.util.List<Sms.Msg> fresh = Sms.fresh();
            for (int i = 0; i < 3 && fresh.isEmpty(); i++) { Thread.sleep(400); fresh = Sms.fresh(); }
            if (!fresh.isEmpty()) {
                for (Sms.Msg s : fresh) {
                    toMac.accept(new JSONObject().put("t", "sms").put("key", m.optString("key"))
                            .put("from", s.address).put("name", m.optString("title"))
                            .put("body", s.body).put("icon", m.optString("icon"))
                            .put("actions", m.optJSONArray("actions")).put("inputs", m.optJSONArray("inputs")));
                }
                return;
            }
        }
        toMac.accept(m);
    }

    /** Mensaje del Mac: guardarlo y pasárselo a la app (arrancándola si hace falta). */
    static void fromMac(JSONObject m) {
        try {
            if ("vol".equals(m.optString("t"))) lastVol = m;
            else {
                lastNp = m;
                if (m.has("art")) lastNpArt = m;
                if (m.optBoolean("none")) lastNpArt = null;
            }
            OutputStream c = client;
            if (c != null) {
                try { write(c, m); return; } catch (Exception e) { client = null; }
            }
            if ("np".equals(m.optString("t")) && !m.optBoolean("none")) ensureService();
        } catch (Exception e) {
            log.accept("media fromMac: " + e);
        }
    }

    private static void ensureService() {
        if (server == null || System.currentTimeMillis() - lastStart < 10000) return;
        lastStart = System.currentTimeMillis();
        try {
            Process p = new ProcessBuilder("am", "start-foreground-service", "-n", SERVICE,
                    "--ei", "port", String.valueOf(server.getLocalPort()), "--es", "token", token)
                    .redirectErrorStream(true).start();
            p.getOutputStream().close();
            p.getInputStream().readAllBytes();
            p.waitFor();
        } catch (Exception e) {
            log.accept("media: no pude iniciar servicio: " + e);
        }
    }

    private static void acceptLoop() {
        while (true) {
            try {
                Socket s = server.accept();
                s.setTcpNoDelay(true);
                new Thread(() -> serve(s), "media-client").start();
            } catch (Exception e) {
                log.accept("media accept: " + e);
                return;
            }
        }
    }

    private static void serve(Socket s) {
        OutputStream os = null;
        try (Socket sock = s) {
            sock.setSoTimeout(5000);
            BufferedReader in = new BufferedReader(new InputStreamReader(sock.getInputStream(), StandardCharsets.UTF_8));
            String first = in.readLine();
            if (first == null) return;
            String[] hello = first.trim().split(" ");
            if (!token.equals(hello[0])) return; // no es nuestra app
            sock.setSoTimeout(0);
            os = sock.getOutputStream();
            if (hello.length > 1 && "notif".equals(hello[1])) { serveNotif(in, os); return; }
            synchronized (MediaRelay.class) { client = os; }
            // Estado actual: carátula primero (si la última actualización no la trae) y luego lo demás
            JSONObject np = lastNp, art = lastNpArt, vol = lastVol;
            if (art != null && np != null && !np.has("art")) write(os, art);
            if (np != null) write(os, np);
            if (vol != null) write(os, vol);
            String line;
            while ((line = in.readLine()) != null) {
                JSONObject m = new JSONObject(line);
                String t = m.optString("t");
                if ("media".equals(t) || "setvol".equals(t)) toMac.accept(m);
            }
        } catch (Exception e) {
            log.accept("media client: " + e);
        } finally {
            final OutputStream o = os;
            synchronized (MediaRelay.class) { if (client == o) client = null; }
        }
    }

    private static void serveNotif(BufferedReader in, OutputStream os) throws Exception {
        synchronized (MediaRelay.class) { notifClient = os; }
        sendConfig(os);
        try {
            String line;
            while ((line = in.readLine()) != null) {
                JSONObject m = new JSONObject(line);
                switch (m.optString("t")) {
                    case "notif": case "call": onNotif(m); break;
                    case "notifRemoved": case "ble": case "dnd": case "smsSent": case "ringState": case "sims":
                    case "smsThreads": case "smsThread": case "smsChanged": case "fileOut": case "home":
                        toMac.accept(m); break;
                    case "openOnMac": toMac.accept(Links.withVideoTime(m)); break;
                }
            }
        } finally {
            synchronized (MediaRelay.class) { if (notifClient == os) notifClient = null; }
        }
    }

    private static void write(OutputStream os, JSONObject m) throws Exception {
        byte[] b = (m.toString() + "\n").getBytes(StandardCharsets.UTF_8);
        synchronized (os) { os.write(b); os.flush(); }
    }
}
