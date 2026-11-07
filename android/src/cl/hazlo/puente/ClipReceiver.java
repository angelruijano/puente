package cl.hazlo.puente;

import android.content.BroadcastReceiver;
import android.content.ClipData;
import android.content.ClipDescription;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.PersistableBundle;

import java.io.File;

/**
 * El Mac sube una imagen a Android/data/cl.hazlo.puente/files/clip/ y envía este broadcast
 * (protegido con el permiso DUMP: solo adb/shell puede enviarlo). Escribir el portapapeles
 * en segundo plano sí está permitido; leerlo no.
 */
public final class ClipReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context ctx, Intent intent) {
        String name = intent.getStringExtra("file");
        String mime = intent.getStringExtra("mime");
        if (name == null || name.contains("/")) return;
        File f = new File(ClipProvider.dir(ctx), name);
        if (!f.exists()) return;

        // Borra imágenes viejas
        File[] all = ClipProvider.dir(ctx).listFiles();
        if (all != null) for (File o : all) if (!o.getName().equals(name)) o.delete();

        Uri uri = Uri.parse("content://" + ClipProvider.AUTHORITY + "/" + name);
        ClipData clip = new ClipData(new ClipDescription("Puente", new String[]{mime != null ? mime : "image/png"}),
                new ClipData.Item(uri));
        PersistableBundle extras = new PersistableBundle();
        extras.putBoolean("cl.hazlo.puente.fromMac", true);
        clip.getDescription().setExtras(extras);
        ((ClipboardManager) ctx.getSystemService(Context.CLIPBOARD_SERVICE)).setPrimaryClip(clip);
    }
}
