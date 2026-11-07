package cl.hazlo.puente.shell;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * Lee SMS nuevos como shell. Android 15+ oculta los códigos a las apps que escuchan notificaciones,
 * pero shell sí puede leer la bandeja de entrada.
 */
final class Sms {
    static final class Msg { long id; String address = ""; String body = ""; }

    private static long lastId = -1;

    /** Fija el punto de partida: solo interesan los SMS que lleguen desde ahora. */
    static synchronized void init() {
        for (Msg m : query(null)) lastId = Math.max(lastId, m.id);
        if (lastId < 0) lastId = 0;
    }

    static synchronized List<Msg> fresh() {
        if (lastId < 0) init();
        List<Msg> r = query("_id>" + lastId);
        for (Msg m : r) lastId = Math.max(lastId, m.id);
        return r;
    }

    private static List<Msg> query(String where) {
        List<Msg> out = new ArrayList<>();
        try {
            List<String> cmd = new ArrayList<>(List.of("content", "query", "--uri", "content://sms/inbox",
                    "--projection", where == null ? "_id" : "_id:address:body", "--sort", "_id ASC"));
            if (where != null) { cmd.add("--where"); cmd.add(where); }
            Process p = new ProcessBuilder(cmd).start();
            p.getOutputStream().close();
            Msg cur = null;
            StringBuilder body = null;
            try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8))) {
                String l;
                while ((l = r.readLine()) != null) {
                    if (l.startsWith("Row: ")) {
                        if (cur != null && body != null) cur.body = body.toString();
                        cur = new Msg(); body = null; out.add(cur);
                        String rest = l.substring(l.indexOf(' ', 5) + 1); // tras "Row: N "
                        int b = rest.indexOf(", body=");
                        String head = b >= 0 ? rest.substring(0, b) : rest;
                        if (b >= 0) body = new StringBuilder(rest.substring(b + 7));
                        for (String kv : head.split(", ")) {
                            if (kv.startsWith("_id=")) cur.id = Long.parseLong(kv.substring(4).trim());
                            else if (kv.startsWith("address=")) cur.address = kv.substring(8);
                        }
                    } else if (body != null) {
                        body.append('\n').append(l); // SMS de varias líneas
                    }
                }
            }
            if (cur != null && body != null) cur.body = body.toString();
            p.waitFor();
        } catch (Exception ignored) {}
        return out;
    }
}
