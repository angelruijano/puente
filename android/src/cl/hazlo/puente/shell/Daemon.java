package cl.hazlo.puente.shell;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

/**
 * Proceso residente (usuario shell) que sigue vivo aunque se corte el enlace con el Mac.
 * Prende y apaga el hotspot (solo para quien tenga el token: la app Puente, en 127.0.0.1) y,
 * con el hotspot encendido, ofrece al Mac el enlace cifrado de {@link NetLink}. Muere al reiniciar el celular; el Mac lo vuelve a lanzar.
 */
public final class Daemon {
    static final int VERSION = 4;
    static final int PORT = 47923;
    static final String DIR = "/data/local/tmp/puente";
    static final String TOKEN_FILE = DIR + "/daemon.token";

    public static void main(String[] args) throws Exception {
        String token = new String(Files.readAllBytes(new File(TOKEN_FILE).toPath()), StandardCharsets.UTF_8).trim();
        ServerSocket server;
        try {
            server = new ServerSocket(PORT, 4, InetAddress.getByName("127.0.0.1"));
        } catch (Exception e) {
            return; // ya hay uno corriendo
        }
        NetLink.start(); // enlace cifrado propio: hotspot y Wi‑Fi de casa
        while (true) {
            Socket s = server.accept();
            new Thread(() -> serve(s, token), "client").start();
        }
    }

    private static void serve(Socket s, String token) {
        try (Socket sock = s) {
            sock.setSoTimeout(15000);
            BufferedReader in = new BufferedReader(new InputStreamReader(sock.getInputStream(), StandardCharsets.UTF_8));
            OutputStream out = sock.getOutputStream();
            String first = in.readLine();
            if (first == null || !token.equals(first.trim())) return;
            String line;
            while ((line = in.readLine()) != null) {
                JSONObject c = new JSONObject(line), r = new JSONObject();
                switch (c.optString("c")) {
                    case "version": r.put("version", VERSION).put("apk", System.getProperty("java.class.path", "")); break;
                    case "hotspot":
                        r.put("code", c.optBoolean("on") ? Tether.start() : Tether.stop());
                        r.put("on", Tether.isOn());
                        break;
                    case "state": r.put("on", Tether.isOn()); break;
                    case "home": NetLink.setHome(c.optBoolean("on")); r.put("ok", true); break;
                    case "quit":
                        out.write("{\"bye\":true}\n".getBytes(StandardCharsets.UTF_8)); out.flush();
                        System.exit(0);
                }
                out.write((r.toString() + "\n").getBytes(StandardCharsets.UTF_8));
                out.flush();
            }
        } catch (Throwable ignored) {}
    }

    // ---------- usado por el ayudante ----------

    /** Asegura que el residente corra con la versión actual; devuelve el token (o null si falló). */
    static String ensure(String apkPath) {
        try {
            File dir = new File(DIR);
            dir.mkdirs();
            dir.setReadable(false, false); dir.setExecutable(false, false);
            dir.setReadable(true, true); dir.setExecutable(true, true);
            File tf = new File(TOKEN_FILE);
            if (!tf.exists()) {
                byte[] b = new byte[24];
                new java.security.SecureRandom().nextBytes(b);
                StringBuilder sb = new StringBuilder();
                for (byte x : b) sb.append(String.format("%02x", x));
                Files.write(tf.toPath(), sb.toString().getBytes(StandardCharsets.UTF_8));
                tf.setReadable(false, false); tf.setReadable(true, true);
            }
            String token = new String(Files.readAllBytes(tf.toPath()), StandardCharsets.UTF_8).trim();
            JSONObject info = ask(token, "{\"c\":\"version\"}");
            int v = info.optInt("version", -1);
            // Misma versión y mismo APK: sigue el que corre. Si la app se actualizó, se relanza con el código nuevo.
            if (v == VERSION && apkPath.equals(info.optString("apk"))) return token;
            if (v != -1) { ask(token, "{\"c\":\"quit\"}"); Thread.sleep(500); }
            new ProcessBuilder("sh", "-c", "CLASSPATH=" + apkPath
                    + " setsid app_process / cl.hazlo.puente.shell.Daemon </dev/null >/dev/null 2>&1 &")
                    .start().waitFor();
            for (int i = 0; i < 20; i++) {
                Thread.sleep(250);
                if (ask(token, "{\"c\":\"version\"}").optInt("version", -1) == VERSION) return token;
            }
        } catch (Exception ignored) {}
        return null;
    }

    private static JSONObject ask(String token, String cmd) {
        try (Socket s = new Socket(InetAddress.getByName("127.0.0.1"), PORT)) {
            s.setSoTimeout(3000);
            OutputStream o = s.getOutputStream();
            o.write((token + "\n" + cmd + "\n").getBytes(StandardCharsets.UTF_8));
            o.flush();
            String l = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8)).readLine();
            return l == null ? new JSONObject() : new JSONObject(l);
        } catch (Exception e) {
            return new JSONObject();
        }
    }
}
