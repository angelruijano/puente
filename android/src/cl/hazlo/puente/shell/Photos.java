package cl.hazlo.puente.shell;

import android.util.Base64;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.function.Consumer;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Fotos y capturas nuevas del celular → Mac, apenas se guardan. */
final class Photos {
    static volatile boolean enabled = true;
    private static final long MAX = 40L * 1024 * 1024;
    private static final Pattern ROW = Pattern.compile(
            "_id=(\\d+), _data=(.*), mime_type=(\\S*), relative_path=(.*), _size=(\\d+)$");

    static void start(Consumer<JSONObject> send, Consumer<String> log) {
        Thread t = new Thread(() -> {
            long last = maxId();
            while (true) {
                try { Thread.sleep(2000); } catch (InterruptedException e) { return; }
                try {
                    if (last < 0) { last = maxId(); continue; }
                    for (String[] r : query("_id>" + last + " AND is_pending=0")) {
                        long id = Long.parseLong(r[0]);
                        last = Math.max(last, id);
                        if (!enabled) continue;
                        String rel = r[3];
                        boolean shot = rel.contains("Screenshots");
                        if (!shot && !rel.startsWith("DCIM/Camera")) continue;
                        File f = new File(r[1]);
                        if (!f.isFile() || f.length() > MAX) continue;
                        byte[] data = Files.readAllBytes(f.toPath());
                        send.accept(new JSONObject().put("t", "photo").put("name", f.getName()).put("mime", r[2])
                                .put("shot", shot).put("b64", Base64.encodeToString(data, Base64.NO_WRAP)));
                    }
                } catch (Throwable e) { log.accept("photos: " + e); }
            }
        }, "photos");
        t.setDaemon(true);
        t.start();
    }

    private static long maxId() {
        try {
            long max = 0;
            for (String[] r : query(null)) max = Math.max(max, Long.parseLong(r[0]));
            return max;
        } catch (Exception e) { return -1; }
    }

    private static java.util.List<String[]> query(String where) throws Exception {
        java.util.List<String> cmd = new java.util.ArrayList<>(java.util.List.of("content", "query", "--uri",
                "content://media/external/images/media", "--projection", "_id:_data:mime_type:relative_path:_size"));
        if (where != null) { cmd.add("--where"); cmd.add(where); }
        Process p = new ProcessBuilder(cmd).redirectErrorStream(true).start();
        p.getOutputStream().close();
        java.util.List<String[]> out = new java.util.ArrayList<>();
        try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8))) {
            String l;
            while ((l = r.readLine()) != null) {
                Matcher m = ROW.matcher(l);
                if (m.find()) out.add(new String[]{m.group(1), m.group(2), m.group(3), m.group(4), m.group(5)});
            }
        }
        p.waitFor();
        return out;
    }
}
