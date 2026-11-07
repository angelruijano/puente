package cl.hazlo.puente.shell;

import android.net.Uri;

import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Archivos por el enlace propio, en binario (sin base64 ni JSON por trozo).
 * Una conexión aparte por lote, para no frenar la sesión normal. Pedidos del Mac, uno tras otro:
 *   {"op":"mkdir","name":n}                 → {"ok":true,"path":carpeta nueva en Descargas}
 *   {"op":"put","name":n,"size":s}          → s bytes en marcos → {"ok":true,"path":...}
 *   {"op":"put","dir":d,"rel":"a/b.jpg","size":s}  (d = carpeta creada con mkdir en esta conexión)
 *   {"op":"get","path":p}                   → {"ok":true,"size":s} y s bytes en marcos (solo la carpeta de salida)
 *   {"op":"rm","dir":d}                     → {"ok":true} (solo dentro de la carpeta de salida)
 */
final class FileLink {
    private static final String DOWNLOAD = "/sdcard/Download/";
    private static final String OUT = "/storage/emulated/0/Android/data/cl.hazlo.puente/files/out/";
    private static final int CHUNK = 1024 * 1024;
    private static final ExecutorService scanner = Executors.newSingleThreadExecutor();

    static void serve(NetLink.Chan ch) throws Exception {
        Set<String> made = new HashSet<>();
        byte[] req;
        while ((req = ch.read()) != null) {
            JSONObject m = new JSONObject(new String(req, StandardCharsets.UTF_8));
            JSONObject r = new JSONObject().put("ok", false);
            switch (m.optString("op")) {
                case "mkdir": {
                    File d = unique(new File(DOWNLOAD), clean(m.optString("name")));
                    if (d.mkdirs()) { made.add(d.getAbsolutePath()); r.put("ok", true).put("path", d.getAbsolutePath()); }
                    ch.write(r.toString().getBytes(StandardCharsets.UTF_8));
                    break;
                }
                case "put": {
                    long size = m.optLong("size", -1);
                    File f = target(m, made);
                    if (f == null || size < 0) { ch.write(r.put("err", "destino no válido").toString().getBytes(StandardCharsets.UTF_8)); return; }
                    long got = 0;
                    try (FileOutputStream o = new FileOutputStream(f)) {
                        while (got < size) {
                            byte[] b = ch.read();
                            if (b == null) { o.close(); f.delete(); return; }
                            o.write(b);
                            got += b.length;
                        }
                    }
                    scan(f);
                    ch.write(r.put("ok", true).put("path", f.getAbsolutePath()).toString().getBytes(StandardCharsets.UTF_8));
                    break;
                }
                case "get": {
                    String p = m.optString("path");
                    File f = new File(p);
                    if (!p.startsWith(OUT) || p.contains("..") || !f.isFile()) {
                        ch.write(r.toString().getBytes(StandardCharsets.UTF_8)); break; }
                    long size = f.length();
                    ch.write(r.put("ok", true).put("size", size).toString().getBytes(StandardCharsets.UTF_8));
                    byte[] buf = new byte[CHUNK];
                    long sent = 0;
                    try (FileInputStream in = new FileInputStream(f)) {
                        int n;
                        while (sent < size && (n = in.read(buf, 0, (int) Math.min(buf.length, size - sent))) > 0) {
                            ch.write(buf, 0, n);
                            sent += n;
                        }
                    }
                    if (sent < size) return; // el archivo cambió a medio camino: cortar
                    break;
                }
                case "rm": {
                    String d = m.optString("dir");
                    if (d.startsWith(OUT) && !d.contains("..")) {
                        new ProcessBuilder("rm", "-rf", d).start().waitFor();
                        r.put("ok", true);
                    }
                    ch.write(r.toString().getBytes(StandardCharsets.UTF_8));
                    break;
                }
                default: return;
            }
        }
    }

    /** Dónde guardar: suelto en Descargas (sin pisar nada) o dentro de una carpeta creada en esta conexión. */
    private static File target(JSONObject m, Set<String> made) {
        String dir = m.optString("dir", "");
        if (dir.isEmpty()) return unique(new File(DOWNLOAD), clean(m.optString("name")));
        if (!made.contains(dir)) return null;
        File f = new File(dir);
        for (String part : m.optString("rel").split("/")) {
            if (part.isEmpty() || part.equals(".") || part.equals("..")) return null;
            f = new File(f, clean(part));
        }
        File parent = f.getParentFile();
        if (parent != null) parent.mkdirs();
        return f;
    }

    private static String clean(String s) {
        String r = new File(s.replaceAll("[\\\\:\\x00-\\x1f]", "_")).getName().trim();
        return r.isEmpty() || r.startsWith(".") ? "archivo" + r : r;
    }

    private static File unique(File dir, String name) {
        File f = new File(dir, name);
        int dot = name.lastIndexOf('.');
        String base = dot > 0 ? name.substring(0, dot) : name, ext = dot > 0 ? name.substring(dot) : "";
        for (int i = 2; f.exists(); i++) f = new File(dir, base + " " + i + ext);
        return f;
    }

    /** Que aparezca en Fotos/Archivos. En segundo plano: cada aviso lanza un proceso. */
    private static void scan(File f) {
        scanner.execute(() -> {
            try {
                new ProcessBuilder("am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                        "-d", "file://" + Uri.encode(f.getAbsolutePath(), "/"))
                        .redirectErrorStream(true).redirectOutput(new File("/dev/null")).start().waitFor();
            } catch (Exception ignored) {}
        });
    }
}
