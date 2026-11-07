package cl.hazlo.puente.shell;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;

import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * Enlace propio con el Mac, sin adb: por el hotspot del celular y por el Wi‑Fi de casa.
 *
 * Vive en el proceso residente. Acepta solo:
 *  - con el hotspot encendido, por la red del hotspot;
 *  - en casa (redes de confianza elegidas en la app, que lo informa), por el Wi‑Fi (wlan0).
 * Nunca por los datos móviles ni por otras redes.
 *
 * Saludo: llaves efímeras X25519 + nonces; las llaves de la sesión salen de HKDF sobre la llave
 * compartida (la que el Mac dejó por adb) y el secreto efímero. Sin la llave compartida no se entra;
 * y aunque se filtrara después, no sirve para descifrar sesiones grabadas.
 * Marcos [largo][AES‑256‑GCM], con contador como nonce.
 *
 * Primer mensaje del Mac: "puente" (sesión con el ayudante) o "files" (archivos en binario, ver FileLink).
 */
final class NetLink {
    static final int PORT = 47930;
    static final String KEY_FILE = Daemon.DIR + "/net.key";
    private static final byte[] MAGIC = "PNT2".getBytes(StandardCharsets.US_ASCII);
    static final int MAX_FRAME = 8 * 1024 * 1024;
    /** Cuánto vale el aviso "estoy en casa" de la app si no lo renueva (lo renueva cada 15 min). */
    private static final long HOME_TTL = 40 * 60_000L;

    private static Socket current;
    private static Process currentHelper;
    private static volatile long homeAt = 0;

    /** La app informa si el celular está en el Wi‑Fi de casa. */
    static void setHome(boolean on) {
        homeAt = on ? System.currentTimeMillis() : 0;
        note("en casa: " + on);
    }

    static boolean atHome() { return homeAt != 0 && System.currentTimeMillis() - homeAt < HOME_TTL; }

    static void start() {
        Thread t = new Thread(() -> {
            ServerSocket server;
            try { server = new ServerSocket(PORT, 8, InetAddress.getByName("0.0.0.0")); }
            catch (Exception e) { return; }
            while (true) {
                try {
                    Socket s = server.accept();
                    if (!allowed(s)) { s.close(); continue; }
                    new Thread(() -> serve(s), "net-client").start();
                } catch (Exception ignored) {}
            }
        }, "net");
        t.setDaemon(true);
        t.start();
    }

    /** Solo red local, y solo por el hotspot (encendido) o por el Wi‑Fi de casa. */
    private static boolean allowed(Socket s) {
        try {
            if (!s.getInetAddress().isSiteLocalAddress()) return false;
            NetworkInterface ni = NetworkInterface.getByInetAddress(s.getLocalAddress());
            String n = ni == null ? "" : ni.getName();
            if (n.equals("wlan0")) return atHome();
            boolean ap = n.startsWith("wlan") || n.startsWith("swlan") || n.startsWith("ap") || n.startsWith("softap");
            return ap && Tether.isOn();
        } catch (Exception e) { return false; }
    }

    /** IPv4 del celular en el Wi‑Fi (para que el Mac lo encuentre en casa), o null. */
    static String wifiAddress() {
        try {
            NetworkInterface ni = NetworkInterface.getByName("wlan0");
            if (ni == null || !ni.isUp()) return null;
            for (InetAddress a : java.util.Collections.list(ni.getInetAddresses()))
                if (a instanceof Inet4Address && a.isSiteLocalAddress()) return a.getHostAddress();
        } catch (Exception ignored) {}
        return null;
    }

    private static void serve(Socket s) {
        Process helper = null;
        try {
            Chan ch = Chan.accept(s);
            if (ch == null) { s.close(); return; }
            byte[] first = ch.read();
            String purpose = first == null ? "" : new String(first, StandardCharsets.UTF_8);
            if (!purpose.equals("puente") && !purpose.equals("files") && !purpose.equals("probe")) { s.close(); return; }
            ch.write("ok".getBytes(StandardCharsets.UTF_8)); // el Mac comprueba que también tenemos la llave
            if (purpose.equals("probe")) { s.close(); return; } // el Mac solo quería saber si el enlace responde
            if (purpose.equals("files")) {
                s.setSoTimeout(120_000);
                FileLink.serve(ch);
                return;
            }
            s.setSoTimeout(0);

            synchronized (NetLink.class) { // una sola sesión: la nueva reemplaza a la anterior
                if (current != null) try { current.close(); } catch (Exception ignored) {}
                if (currentHelper != null) currentHelper.destroy();
            }
            String apk = apkPath();
            if (apk == null) { note("sin ruta del apk"); s.close(); return; }
            note("sesión abierta por " + s.getLocalAddress().getHostAddress());
            helper = new ProcessBuilder("sh", "-c", "CLASSPATH=" + apk + " exec app_process / cl.hazlo.puente.shell.Helper")
                    .redirectError(new File(Daemon.DIR + "/helper.err")).start(); // DISCARD hace fallar al ayudante en Android
            synchronized (NetLink.class) { current = s; currentHelper = helper; }

            final Process h = helper;
            Thread up = new Thread(() -> { // ayudante → Mac
                try (InputStream hs = h.getInputStream()) {
                    byte[] buf = new byte[64 * 1024];
                    int r;
                    while ((r = hs.read(buf)) > 0) ch.write(Arrays.copyOf(buf, r));
                    note("el ayudante cerró su salida");
                } catch (Throwable e) { note("subida: " + e); }
                try { s.close(); } catch (Exception ignored) {}
            }, "net-up");
            up.start();
            try (OutputStream hin = h.getOutputStream()) { // Mac → ayudante
                byte[] chunk;
                while ((chunk = ch.read()) != null) { hin.write(chunk); hin.flush(); }
            }
            note("sesión cerrada por el Mac");
        } catch (Throwable e) {
            note("sesión: " + e);
        } finally {
            try { s.close(); } catch (Exception ignored) {}
            if (helper != null) helper.destroy();
            synchronized (NetLink.class) { if (current == s) { current = null; currentHelper = null; } }
        }
    }

    /** Registro mínimo (sin contenido) para diagnosticar el enlace. */
    static void note(String m) {
        File f = new File(Daemon.DIR + "/net.log");
        try (java.io.FileWriter w = new java.io.FileWriter(f, f.length() < 64 * 1024)) {
            w.write(new java.util.Date() + " " + m + "\n");
        } catch (Exception ignored) {}
    }

    private static byte[] readKey() {
        try {
            String hex = new String(Files.readAllBytes(new File(KEY_FILE).toPath()), StandardCharsets.UTF_8).trim();
            if (hex.length() != 64) return null;
            byte[] k = new byte[32];
            for (int i = 0; i < 32; i++) k[i] = (byte) Integer.parseInt(hex.substring(i * 2, i * 2 + 2), 16);
            return k;
        } catch (Exception e) { return null; }
    }

    /** La ruta del APK cambia al actualizar la app: se busca cada vez. */
    private static String apkPath() {
        try {
            Process p = new ProcessBuilder("pm", "path", "cl.hazlo.puente").redirectErrorStream(true).start();
            String o = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8).trim();
            p.waitFor();
            for (String l : o.split("\n")) if (l.startsWith("package:") && l.endsWith("base.apk")) return l.substring(8).trim();
            return o.startsWith("package:") ? o.split("\n")[0].substring(8).trim() : null;
        } catch (Exception e) { return null; }
    }

    static byte[] hkdf(byte[] ikm, byte[] salt, String info) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(salt, "HmacSHA256"));
        byte[] prk = mac.doFinal(ikm);
        mac.init(new SecretKeySpec(prk, "HmacSHA256"));
        mac.update(info.getBytes(StandardCharsets.UTF_8));
        mac.update((byte) 1);
        return mac.doFinal();
    }

    /** Conexión ya autenticada y cifrada en ambos sentidos. */
    static final class Chan {
        private final DataInputStream in;
        private final DataOutputStream out;
        private final Box rx, tx;

        private Chan(DataInputStream in, DataOutputStream out, Box rx, Box tx) { this.in = in; this.out = out; this.rx = rx; this.tx = tx; }

        static Chan accept(Socket s) throws Exception {
            byte[] key = readKey();
            if (key == null) return null;
            s.setSoTimeout(10_000);
            s.setTcpNoDelay(true);
            DataInputStream in = new DataInputStream(new java.io.BufferedInputStream(s.getInputStream(), 256 * 1024));
            DataOutputStream out = new DataOutputStream(s.getOutputStream());

            byte[] hello = new byte[4 + 32 + 16];
            in.readFully(hello);
            if (!Arrays.equals(Arrays.copyOf(hello, 4), MAGIC)) return null;
            byte[] cpub = Arrays.copyOfRange(hello, 4, 36), nc = Arrays.copyOfRange(hello, 36, 52);
            SecureRandom rnd = new SecureRandom();
            byte[] priv = new byte[32], ns = new byte[16];
            rnd.nextBytes(priv); rnd.nextBytes(ns);
            byte[] spub = X25519.publicKey(priv);
            byte[] dh = X25519.shared(priv, cpub);
            if (MessageDigest.isEqual(dh, new byte[32])) return null; // llave pública inválida
            out.write(MAGIC); out.write(spub); out.write(ns); out.flush();

            byte[] salt = ByteBuffer.allocate(96).put(nc).put(ns).put(cpub).put(spub).array();
            byte[] ikm = ByteBuffer.allocate(64).put(key).put(dh).array();
            return new Chan(in, out,
                    new Box(hkdf(ikm, salt, "puente2 c2s")), new Box(hkdf(ikm, salt, "puente2 s2c")));
        }

        byte[] read() throws Exception { return rx.read(in); }
        void write(byte[] plain) throws Exception { tx.write(out, plain, 0, plain.length); }
        void write(byte[] b, int off, int len) throws Exception { tx.write(out, b, off, len); }
    }

    /** Un sentido del canal: marcos [largo][cifrado+etiqueta], con contador como nonce. */
    static final class Box {
        private final SecretKeySpec key;
        private long counter = 0;

        Box(byte[] k) { this.key = new SecretKeySpec(k, "AES"); }

        private byte[] nonce() {
            return ByteBuffer.allocate(12).putInt(0).putLong(counter++).array();
        }

        synchronized void write(DataOutputStream out, byte[] plain, int off, int len) throws Exception {
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.ENCRYPT_MODE, key, new GCMParameterSpec(128, nonce()));
            byte[] ct = c.doFinal(plain, off, len);
            out.writeInt(ct.length);
            out.write(ct);
            out.flush();
        }

        byte[] read(DataInputStream in) throws Exception {
            int n;
            try { n = in.readInt(); } catch (java.io.EOFException e) { return null; }
            if (n < 16 || n > MAX_FRAME) return null;
            byte[] ct = new byte[n];
            in.readFully(ct);
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, nonce()));
            return c.doFinal(ct); // falla si alguien alteró o repitió un marco
        }
    }
}
