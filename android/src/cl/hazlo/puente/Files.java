package cl.hazlo.puente;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;

import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.List;

/** Archivos entre el celular y el Mac, estilo AirDrop. Los bytes viajan por adb (rápido), no por el canal JSON. */
final class Files {
    private static final String CHANNEL = "files";

    /** Carpeta de salida que el Mac lee por adb y vacía al terminar. */
    static File outDir(Context c) { return new File(c.getExternalFilesDir(null), "out"); }

    /**
     * Copia lo compartido a la carpeta de salida y avisa al Mac, que lo trae a Descargas.
     * Corre en un hilo propio: un video grande tarda unos segundos en copiarse.
     */
    static void sendToMac(Context c, List<Uri> uris, Runnable failed, Runnable done) {
        new Thread(() -> {
            NotifListener l = NotifListener.instance;
            if (l == null) { failed.run(); return; }
            cleanOld(c);
            File dir = new File(outDir(c), String.valueOf(System.currentTimeMillis()));
            if (!dir.mkdirs()) { failed.run(); return; }
            int n = 0;
            for (Uri u : uris) {
                try {
                    String name = safeName(displayName(c, u));
                    File f = unique(dir, name);
                    try (InputStream in = c.getContentResolver().openInputStream(u); OutputStream out = new FileOutputStream(f)) {
                        if (in == null) continue;
                        byte[] buf = new byte[1 << 16];
                        int r;
                        while ((r = in.read(buf)) > 0) out.write(buf, 0, r);
                    }
                    String mime = c.getContentResolver().getType(u);
                    JSONObject m = new JSONObject().put("t", "fileOut").put("path", f.getAbsolutePath())
                            .put("name", f.getName()).put("size", f.length()).put("mime", mime == null ? "" : mime)
                            .put("dir", dir.getAbsolutePath()).put("index", n).put("count", uris.size());
                    if (!l.sendToMac(m)) { failed.run(); return; }
                    n++;
                } catch (Throwable e) { android.util.Log.e("PuenteFiles", "fileOut " + u, e); }
            }
            if (n == 0) failed.run();
        }, "puente-files") {
            @Override public void run() { try { super.run(); } finally { done.run(); } }
        }.start();
    }

    /** El Mac dejó archivos en Descargas: aviso con acceso directo a la carpeta. */
    static void received(Context c, JSONObject m) {
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Archivos del Mac", NotificationManager.IMPORTANCE_HIGH));
        int count = m.optInt("count", 1);
        String title = count == 1 ? m.optString("name") : count + " archivos";
        Intent open = new Intent("android.intent.action.VIEW_DOWNLOADS").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        PendingIntent pi = PendingIntent.getActivity(c, 7, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification n = new Notification.Builder(c, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle("Recibido de tu Mac")
                .setContentText(title + " · en Descargas")
                .setContentIntent(pi)
                .setAutoCancel(true)
                .build();
        nm.notify(("file:" + title).hashCode(), n);
    }

    private static String displayName(Context c, Uri u) {
        if ("file".equals(u.getScheme()) && u.getLastPathSegment() != null) return u.getLastPathSegment();
        try (Cursor cur = c.getContentResolver().query(u, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (cur != null && cur.moveToFirst() && cur.getString(0) != null) return cur.getString(0);
        } catch (Exception ignored) {}
        String ext = android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(c.getContentResolver().getType(u));
        return "archivo" + (ext == null ? "" : "." + ext);
    }

    private static String safeName(String s) {
        String r = s.replaceAll("[/\\\\:\\x00-\\x1f]", "_").trim();
        return r.isEmpty() || r.startsWith(".") ? "archivo" + r : r;
    }

    private static File unique(File dir, String name) {
        File f = new File(dir, name);
        int dot = name.lastIndexOf('.');
        String base = dot > 0 ? name.substring(0, dot) : name, ext = dot > 0 ? name.substring(dot) : "";
        for (int i = 2; f.exists(); i++) f = new File(dir, base + " " + i + ext);
        return f;
    }

    /** Restos de envíos que el Mac no alcanzó a traer (más de un día). */
    private static void cleanOld(Context c) {
        File[] old = outDir(c).listFiles();
        if (old == null) return;
        for (File d : old) if (System.currentTimeMillis() - d.lastModified() > 86_400_000L) deleteTree(d);
    }

    private static void deleteTree(File f) {
        File[] k = f.listFiles();
        if (k != null) for (File x : k) deleteTree(x);
        f.delete();
    }
}
