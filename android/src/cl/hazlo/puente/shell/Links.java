package cl.hazlo.puente.shell;

import android.os.SystemClock;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Links entre el celular y el Mac. Un video de YouTube sigue en el Mac donde lo dejaste. */
final class Links {
    private static final Pattern STATE = Pattern.compile(
            "state=PlaybackState \\{state=\\w+\\((\\d+)\\), position=(\\d+),.*?speed=([0-9.]+), updated=(\\d+)");

    static JSONObject withVideoTime(JSONObject m) {
        try {
            String url = m.optString("url");
            if (!(url.contains("youtu.be/") || url.contains("youtube.com/watch") || url.contains("youtube.com/shorts"))) return m;
            if (url.matches(".*[?&]t=\\d+.*")) return m;
            long ms = youtubePosition();
            if (ms < 5000) return m;
            m.put("url", url + (url.contains("?") ? "&" : "?") + "t=" + (ms / 1000) + "s");
        } catch (Exception ignored) {}
        return m;
    }

    /** Posición actual del reproductor de YouTube, leída de las sesiones de medios (como shell). */
    private static long youtubePosition() throws Exception {
        Process p = new ProcessBuilder("dumpsys", "media_session").redirectErrorStream(true).start();
        p.getOutputStream().close();
        boolean inYt = false;
        long best = -1;
        try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()))) {
            String l;
            while ((l = r.readLine()) != null) {
                l = l.trim();
                if (l.startsWith("package=")) inYt = l.equals("package=com.google.android.youtube");
                else if (inYt && l.startsWith("state=PlaybackState")) {
                    Matcher mm = STATE.matcher(l);
                    if (mm.find()) {
                        int state = Integer.parseInt(mm.group(1));
                        long pos = Long.parseLong(mm.group(2));
                        float speed = Float.parseFloat(mm.group(3));
                        long updated = Long.parseLong(mm.group(4));
                        if (state == 3) pos += (long) ((SystemClock.elapsedRealtime() - updated) * speed); // reproduciendo
                        if (state == 2 || state == 3) best = Math.max(best, pos);
                    }
                }
            }
        }
        p.waitFor();
        return best;
    }
}
