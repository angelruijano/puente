package cl.hazlo.puente;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.IBinder;
import android.os.Parcel;
import android.provider.Settings;

/**
 * Luces Glyph del Nothing Phone, hablando directo con el servicio del sistema (com.nothing.thirdparty).
 * Es la misma interfaz que usa el kit oficial de Nothing; en modo desarrollador acepta la clave "test".
 */
final class Glyph {
    private static final String DESCRIPTOR = "com.nothing.thirdparty.IGlyphService";
    private static final int SET_FRAME = 1, OPEN = 2, CLOSE = 3, REGISTER = 4, REGISTER_SDK = 5;
    private static final String DEVICE_PHONE_2 = "22111";
    private static final int ZONES = 33;      // Phone (2): 33 zonas
    private static final int MAX = 4095;

    private static IBinder service;
    private static ServiceConnection conn;
    private static boolean ready;
    private static Runnable pending;

    /** Conecta y abre sesión; luego llama a then (en el hilo principal). */
    static void open(Context c, Runnable then) {
        Context app = c.getApplicationContext();
        if (ready) { if (then != null) then.run(); return; }
        pending = then;
        if (conn != null) return;
        try { Settings.Global.putInt(app.getContentResolver(), "nt_glyph_interface_debug_enable", 1); } catch (Exception ignored) {}
        conn = new ServiceConnection() {
            @Override public void onServiceConnected(ComponentName n, IBinder b) {
                service = b;
                boolean ok = callBool(REGISTER_SDK, "test", DEVICE_PHONE_2) || callBool(REGISTER, DEVICE_PHONE_2, null);
                call(OPEN, null);
                ready = true;
                android.util.Log.i("Puente", "glyph: listo (registro " + ok + ")");
                Runnable r = pending; pending = null;
                if (r != null) r.run();
            }
            @Override public void onServiceDisconnected(ComponentName n) { service = null; ready = false; }
        };
        Intent i = new Intent("com.nothing.thirdparty.bind_glyphservice")
                .setComponent(new ComponentName("com.nothing.thirdparty", "com.nothing.thirdparty.GlyphService"));
        try {
            if (!app.bindService(i, conn, Context.BIND_AUTO_CREATE)) { conn = null; android.util.Log.w("Puente", "glyph: no se pudo enlazar"); }
        } catch (Exception e) { conn = null; android.util.Log.w("Puente", "glyph", e); }
    }

    /** Todas las luces a un brillo de 0 a 1. */
    static void all(float level) {
        if (!ready) return;
        int[] f = new int[ZONES];
        java.util.Arrays.fill(f, Math.round(MAX * Math.max(0, Math.min(1, level))));
        call(SET_FRAME, f);
    }

    static void close(Context c) {
        if (ready) { all(0); call(CLOSE, null); }
        ready = false;
        pending = null;
        if (conn != null) try { c.getApplicationContext().unbindService(conn); } catch (Exception ignored) {}
        conn = null;
        service = null;
    }

    private static void call(int code, int[] frame) {
        IBinder b = service;
        if (b == null) return;
        Parcel d = Parcel.obtain(), r = Parcel.obtain();
        try {
            d.writeInterfaceToken(DESCRIPTOR);
            if (frame != null) d.writeIntArray(frame);
            b.transact(code, d, r, 0);
            r.readException();
        } catch (Exception e) {
            android.util.Log.w("Puente", "glyph " + code + ": " + e);
        } finally { d.recycle(); r.recycle(); }
    }

    private static boolean callBool(int code, String a, String b2) {
        IBinder b = service;
        if (b == null) return false;
        Parcel d = Parcel.obtain(), r = Parcel.obtain();
        try {
            d.writeInterfaceToken(DESCRIPTOR);
            d.writeString(a);
            if (b2 != null) d.writeString(b2);
            b.transact(code, d, r, 0);
            r.readException();
            return r.readInt() != 0;
        } catch (Exception e) {
            android.util.Log.w("Puente", "glyph registro " + code + ": " + e);
            return false;
        } finally { d.recycle(); r.recycle(); }
    }
}
