package cl.hazlo.puente;

import android.app.job.JobInfo;
import android.app.job.JobScheduler;
import android.content.ComponentName;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.database.ContentObserver;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.util.Log;

import java.util.Set;

/**
 * Depuración inalámbrica apagada por defecto (necesita WRITE_SECURE_SETTINGS, concedido por adb).
 * El Mac usa su enlace propio; la pide solo cuando hace falta adb (tras reiniciar el celular, para
 * ver la pantalla), por ese enlace o por Bluetooth. Se enciende solo en redes de confianza y se apaga
 * sola a los pocos minutos si el Mac no la renueva. En cualquier otra red la apaga siempre.
 * También le dice al proceso residente si el celular está en casa (ahí acepta el enlace propio por Wi‑Fi).
 */
final class WifiDebug {
    /** Redes de confianza (las de tu casa): se eligen en la app. Fuera de ellas no hay depuración ni enlace por Wi‑Fi. */
    static Set<String> trustedSet(Context c) {
        return new java.util.HashSet<>(prefs(c).getStringSet("trustedSsids", java.util.Collections.emptySet()));
    }

    static void setTrusted(Context c, Set<String> s) {
        prefs(c).edit().putStringSet("trustedSsids", new java.util.HashSet<>(s)).apply();
        apply(c);
    }
    private static final String KEY = "adb_wifi_enabled";

    static boolean canWrite(Context c) {
        return c.checkSelfPermission("android.permission.WRITE_SECURE_SETTINGS") == PackageManager.PERMISSION_GRANTED;
    }

    static boolean isOn(Context c) {
        return Settings.Global.getInt(c.getContentResolver(), KEY, 0) == 1;
    }

    /** Nombre de la red Wi‑Fi actual, o null si no hay Wi‑Fi o no se puede saber (p. ej. ubicación apagada). */
    static String currentSsid(Context c) {
        try {
            WifiInfo wi = c.getSystemService(WifiManager.class).getConnectionInfo();
            return clean(wi == null ? null : wi.getSSID());
        } catch (Exception e) { return null; }
    }

    private static String clean(String ssid) {
        if (ssid == null || ssid.equals(WifiManager.UNKNOWN_SSID) || ssid.isEmpty()) return null;
        if (ssid.length() >= 2 && ssid.startsWith("\"") && ssid.endsWith("\"")) ssid = ssid.substring(1, ssid.length() - 1);
        return ssid;
    }

    private static volatile Context appCtx;

    static boolean trusted(String ssid) {
        Context c = appCtx;
        return ssid != null && c != null && trustedSet(c).contains(ssid);
    }

    /** Cuánto dura un pedido del Mac; él lo renueva cada 2 min mientras la necesita. */
    private static final long LEASE_MS = 5 * 60_000L;
    private static final Handler main = new Handler(Looper.getMainLooper());

    private static SharedPreferences prefs(Context c) { return c.getSharedPreferences("link", Context.MODE_PRIVATE); }

    /** Revisa la red actual: apaga fuera de casa o si venció el pedido, y avisa al residente. */
    static void apply(Context c) { apply(c, currentSsid(c), false); }

    /** ssid null = no se sabe (p. ej. ubicación apagada); lost = ya no hay Wi‑Fi. */
    static void apply(Context c, String ssid, boolean lost) {
        appCtx = c.getApplicationContext();
        if (trusted(ssid)) reportHome(c, true);
        else if (ssid != null || lost) reportHome(c, false);
        if (!canWrite(c)) return;
        try {
            if (trusted(ssid)) {
                if (Settings.Global.getInt(c.getContentResolver(), Settings.Global.ADB_ENABLED, 0) != 1)
                    Settings.Global.putInt(c.getContentResolver(), Settings.Global.ADB_ENABLED, 1);
                expire(c);
            } else if (ssid != null && isOn(c)) {
                off(c, "red no confiable");
            }
        } catch (SecurityException ignored) {}
    }

    /** El Mac necesita adb: encender unos minutos, solo en casa. */
    static boolean request(Context c) {
        appCtx = c.getApplicationContext();
        if (!canWrite(c) || !trusted(currentSsidOr(c))) return false;
        try {
            if (Settings.Global.getInt(c.getContentResolver(), Settings.Global.ADB_ENABLED, 0) != 1)
                Settings.Global.putInt(c.getContentResolver(), Settings.Global.ADB_ENABLED, 1);
            prefs(c).edit().putLong("adbWifiUntil", System.currentTimeMillis() + LEASE_MS).apply();
            if (!isOn(c)) { Settings.Global.putInt(c.getContentResolver(), KEY, 1); Log.i("Puente", "depuración inalámbrica: pedida por el Mac"); }
            scheduleExpiry(c, LEASE_MS);
            return true;
        } catch (SecurityException e) { return false; }
    }

    /** El Mac ya no la necesita. */
    static void release(Context c) {
        prefs(c).edit().putLong("adbWifiUntil", 0).apply();
        if (canWrite(c) && isOn(c)) off(c, "el Mac terminó");
    }

    private static void expire(Context c) {
        long until = prefs(c).getLong("adbWifiUntil", 0);
        if (isOn(c) && System.currentTimeMillis() >= until) off(c, "sin uso");
    }

    private static void scheduleExpiry(Context c, long delay) {
        final Context app = c.getApplicationContext();
        main.removeCallbacksAndMessages(EXPIRY);
        main.postAtTime(() -> { try { expire(app); } catch (Exception ignored) {} }, EXPIRY,
                android.os.SystemClock.uptimeMillis() + delay + 1000);
    }

    private static final Object EXPIRY = new Object();

    private static void off(Context c, String why) {
        try {
            Settings.Global.putInt(c.getContentResolver(), KEY, 0);
            Log.i("Puente", "depuración inalámbrica apagada: " + why);
        } catch (SecurityException ignored) {}
    }

    private static volatile Boolean lastHome;

    /** El residente acepta el enlace por Wi‑Fi solo si sabe que estamos en casa (el aviso dura 40 min; se renueva). */
    static void reportHome(Context c, boolean home) {
        final Context app = c.getApplicationContext();
        lastHome = home;
        new Thread(() -> DaemonClient.ask(app, "{\"c\":\"home\",\"on\":" + home + "}"), "home").start();
    }

    /** Repite el último aviso (p. ej. cuando el residente acaba de arrancar). */
    static void reportHome(Context c) {
        appCtx = c.getApplicationContext();
        String s = currentSsidOr(c);
        if (s != null) reportHome(c, trusted(s));
        else if (lastHome != null) reportHome(c, lastHome);
    }

    private static volatile String lastSsid;
    private static boolean watching;

    /** Vigila cambios de red y del ajuste (vive en el proceso del lector de notificaciones). */
    static synchronized void watch(Context c) {
        if (watching) return;
        watching = true;
        final Context app = c.getApplicationContext();
        appCtx = app;
        ConnectivityManager cm = app.getSystemService(ConnectivityManager.class);
        NetworkRequest req = new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build();
        ConnectivityManager.NetworkCallback cb = Build.VERSION.SDK_INT >= 31
                ? new ConnectivityManager.NetworkCallback(ConnectivityManager.NetworkCallback.FLAG_INCLUDE_LOCATION_INFO) {
                    @Override public void onCapabilitiesChanged(Network n, NetworkCapabilities caps) { onWifi(app, caps); }
                    @Override public void onLost(Network n) { lastSsid = null; apply(app, null, true); }
                }
                : new ConnectivityManager.NetworkCallback() {
                    @Override public void onCapabilitiesChanged(Network n, NetworkCapabilities caps) { onWifi(app, caps); }
                    @Override public void onLost(Network n) { lastSsid = null; apply(app, null, true); }
                };
        cm.registerNetworkCallback(req, cb);
        // Si alguien la enciende en una red ajena, apagarla de nuevo; en casa, encendida a mano dura 10 min
        app.getContentResolver().registerContentObserver(Settings.Global.getUriFor(KEY), false,
                new ContentObserver(new Handler(Looper.getMainLooper())) {
                    @Override public void onChange(boolean self) {
                        if (!isOn(app)) return;
                        String s = currentSsidOr(app);
                        if (s != null && !trusted(s)) { off(app, "red no confiable"); return; }
                        if (System.currentTimeMillis() >= prefs(app).getLong("adbWifiUntil", 0)) {
                            prefs(app).edit().putLong("adbWifiUntil", System.currentTimeMillis() + 2 * LEASE_MS).apply();
                            scheduleExpiry(app, 2 * LEASE_MS);
                        }
                    }
                });
    }

    private static String currentSsidOr(Context c) {
        String s = currentSsid(c);
        return s != null ? s : lastSsid;
    }

    private static void onWifi(Context c, NetworkCapabilities caps) {
        String ssid = null;
        if (caps.getTransportInfo() instanceof WifiInfo) ssid = clean(((WifiInfo) caps.getTransportInfo()).getSSID());
        if (ssid == null) ssid = currentSsid(c);
        lastSsid = ssid;
        apply(c, ssid, false);
    }

    /** Respaldo: cada vez que hay Wi‑Fi y cada 15 min. */
    static void schedule(Context c) {
        JobScheduler js = c.getSystemService(JobScheduler.class);
        ComponentName svc = new ComponentName(c, WifiDebugJob.class);
        js.schedule(new JobInfo.Builder(1, svc)
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_UNMETERED)
                .setPersisted(true)
                .setMinimumLatency(5_000)
                .build());
        js.schedule(new JobInfo.Builder(2, svc)
                .setPeriodic(15 * 60_000L)
                .setPersisted(true)
                .build());
    }
}
