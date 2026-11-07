package cl.hazlo.puente.shell;

import android.util.Base64;

import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Pequeños pedidos de archivos por la sesión del enlace propio (sin adb): borrar lo ya traído
 * y la imagen del portapapeles. Los archivos en sí van en binario por FileLink.
 */
final class NetFiles {
    private static final String OUT = "/storage/emulated/0/Android/data/cl.hazlo.puente/files/out/";
    private static final String CLIP = "/sdcard/Android/data/cl.hazlo.puente/files/clip/";
    private static final ExecutorService q = Executors.newSingleThreadExecutor();

    static void handle(JSONObject m) {
        q.execute(() -> {
            try {
                switch (m.optString("t")) {
                    case "frm": {
                        String dir = m.optString("dir");
                        if (dir.startsWith(OUT) && !dir.contains("..")) Helper.run("rm", "-rf", dir);
                        break;
                    }
                    case "clipImage": {
                        String name = new File(m.optString("name")).getName();
                        new File(CLIP).mkdirs();
                        try (FileOutputStream o = new FileOutputStream(CLIP + name)) { o.write(Base64.decode(m.optString("b64"), 0)); }
                        Helper.run("am", "broadcast", "-n", "cl.hazlo.puente/.ClipReceiver",
                                "--es", "file", name, "--es", "mime", m.optString("mime", "image/png"));
                        break;
                    }
                }
            } catch (Exception e) {
                try { Helper.send(new JSONObject().put("t", "log").put("d", "archivos: " + e)); } catch (Exception ignored) {}
            }
        });
    }

}
