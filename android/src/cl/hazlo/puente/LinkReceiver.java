package cl.hazlo.puente;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** El ayudante (shell, protegido con DUMP) avisa el puerto y token de su socket local. */
public class LinkReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent i) {
        // Prueba desde adb: --es ring on|off
        if (i.hasExtra("glyph")) {
            Context app = ctx.getApplicationContext();
            Glyph.open(app, () -> {
                Glyph.all(1f);
                new android.os.Handler(android.os.Looper.getMainLooper()).postDelayed(() -> Glyph.close(app), 4000);
            });
            return;
        }
        if (i.hasExtra("ring")) { if ("on".equals(i.getStringExtra("ring"))) Ring.start(ctx); else Ring.stop(ctx); return; }
        int port = i.getIntExtra("port", 0);
        String token = i.getStringExtra("token");
        if (port == 0 || token == null) return;
        ctx.getSharedPreferences("link", Context.MODE_PRIVATE).edit()
                .putInt("port", port).putString("token", token).commit();
        NotifListener l = NotifListener.instance;
        if (l != null) l.connect();
        else NotifListener.requestRebind(new android.content.ComponentName(ctx, NotifListener.class));
    }
}
