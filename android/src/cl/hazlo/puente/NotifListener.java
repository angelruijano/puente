package cl.hazlo.puente;

import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.Icon;
import android.os.Bundle;
import android.os.SystemClock;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;
import android.util.Base64;
import android.util.LruCache;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;

/**
 * Reenvía las notificaciones del celular al Mac (vía el ayudante shell).
 * Excluye WhatsApp y Telegram (ya están en el Mac), notificaciones silenciosas, persistentes y de música.
 */
public class NotifListener extends NotificationListenerService {
    private static final Set<String> EXCLUDED = Set.of(
            "com.whatsapp", "com.whatsapp.w4b",
            "org.telegram.messenger", "org.telegram.messenger.web", "org.thunderdog.challegram",
            "cl.hazlo.puente", "android", "com.android.systemui", "com.android.providers.downloads",
            "com.google.android.gms", "com.android.vending");

    static volatile NotifListener instance;

    private final Map<String, StatusBarNotification> active = new HashMap<>();
    private final Map<String, String> sentSig = new HashMap<>();
    private final LruCache<String, String> iconCache = new LruCache<>(64);
    /** Todo el trabajo (íconos, red) fuera del hilo principal y en orden. */
    private final java.util.concurrent.ExecutorService worker = java.util.concurrent.Executors.newSingleThreadExecutor();
    private volatile OutputStream out;
    private volatile Thread conn;
    private Ble ble;
    private final SmsStore smsStore = new SmsStore(this);

    synchronized Ble ble() {
        if (ble == null) ble = new Ble(this, this::send);
        return ble;
    }

    @Override
    public void onListenerConnected() {
        instance = this;
        connect();
        ble().start();
        WifiDebug.watch(this);
        WifiDebug.apply(this);
        smsStore.watch(this::send);
        Ring.onStop = () -> { try { send(new JSONObject().put("t", "ringState").put("on", false)); } catch (Exception ignored) {} };
        // La que ya esté visible al arrancar
        worker.execute(() -> {
            try { for (StatusBarNotification sbn : getActiveNotifications()) hideSystemNoise(sbn); } catch (Exception ignored) {}
        });
    }

    @Override
    public void onListenerDisconnected() {
        if (instance == this) instance = null;
        smsStore.unwatch();
        Thread t = conn; conn = null;
        if (t != null) t.interrupt();
    }

    // ---------- conexión con el ayudante ----------

    /** Llamado al arrancar y cada vez que el ayudante avisa un puerto nuevo. */
    void connect() {
        SharedPreferences p = getSharedPreferences("link", Context.MODE_PRIVATE);
        final int port = p.getInt("port", 0);
        final String token = p.getString("token", null);
        if (port == 0 || token == null) return;
        Thread old = conn;
        Thread t = new Thread(() -> {
            int failures = 0;
            while (conn == Thread.currentThread() && failures < 5) {
                try (Socket s = new Socket()) {
                    s.connect(new InetSocketAddress("127.0.0.1", port), 3000);
                    s.setTcpNoDelay(true);
                    OutputStream os = s.getOutputStream();
                    os.write((token + " notif\n").getBytes(StandardCharsets.UTF_8));
                    os.flush();
                    out = os;
                    failures = 0;
                    sendDnd(getCurrentInterruptionFilter());
                    BufferedReader in = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8));
                    String line;
                    while ((line = in.readLine()) != null) fromMac(new JSONObject(line));
                } catch (Exception e) {
                    failures++;
                } finally {
                    out = null;
                }
                SystemClock.sleep(3000);
            }
        }, "puente-notif");
        conn = t;
        if (old != null) old.interrupt();
        t.start();
    }

    private void fromMac(JSONObject m) {
        if ("config".equals(m.optString("t"))) {
            SharedPreferences.Editor e = getSharedPreferences("link", Context.MODE_PRIVATE).edit();
            boolean newKey = m.has("bleKey") && !m.optString("bleKey").equals(
                    getSharedPreferences("link", Context.MODE_PRIVATE).getString("bleKey", null));
            if (m.has("bleKey")) e.putString("bleKey", m.optString("bleKey"));
            if (m.has("daemonPort")) e.putInt("daemonPort", m.optInt("daemonPort"));
            if (m.has("daemonToken")) e.putString("daemonToken", m.optString("daemonToken"));
            e.commit();
            if (newKey) { ble().stop(); ble().start(); }
            if (m.has("daemonToken")) WifiDebug.reportHome(this); // el residente puede haber arrancado recién
            return;
        }
        switch (m.optString("t")) {
            case "ring": Ring.start(this); return;
            case "ringStop": Ring.stop(this); return;
            case "dnd":
                requestInterruptionFilter(m.optBoolean("on") ? INTERRUPTION_FILTER_PRIORITY : INTERRUPTION_FILTER_ALL);
                return;
            case "smsSend": sendSms(m); return;
            case "sims": sendSims(); return;
            case "fileIn": Files.received(this, m); return;
            case "adbWifi":
                if (m.optBoolean("on")) WifiDebug.request(this); else WifiDebug.release(this);
                return;
            case "smsThreads":
                try { send(smsStore.threads()); } catch (Exception e) { android.util.Log.w("Puente", "smsThreads", e); }
                return;
            case "smsThread":
                try { send(smsStore.thread(m.optLong("id"), m.optInt("limit", 300))); } catch (Exception e) { android.util.Log.w("Puente", "smsThread", e); }
                return;
        }
        String key = m.optString("key");
        StatusBarNotification sbn;
        synchronized (active) { sbn = active.get(key); }
        if (sbn == null) return;
        switch (m.optString("t")) {
            case "notifAction": {
                Notification.Action[] acts = sbn.getNotification().actions;
                int i = m.optInt("i", -1);
                if (acts == null || i < 0 || i >= acts.length || acts[i].actionIntent == null) break;
                Notification.Action a = acts[i];
                try {
                    android.app.RemoteInput[] ins = a.getRemoteInputs();
                    if (m.has("text") && ins != null && ins.length > 0) {
                        // Responder: se llena el cuadro de texto de la notificación, como al escribir en el celular
                        Intent fill = new Intent().addFlags(Intent.FLAG_RECEIVER_FOREGROUND);
                        Bundle res = new Bundle();
                        for (android.app.RemoteInput ri : ins) res.putCharSequence(ri.getResultKey(), m.optString("text"));
                        android.app.RemoteInput.addResultsToIntent(ins, fill, res);
                        a.actionIntent.send(this, 0, fill);
                    } else {
                        a.actionIntent.send();
                    }
                } catch (PendingIntent.CanceledException ignored) {}
                break;
            }
            case "notifDismiss":
                cancelNotification(key);
                break;
        }
    }

    /** SMS nuevo escrito en el Mac. Android lo guarda en la conversación de Mensajes. */
    private void sendSms(JSONObject m) {
        String to = m.optString("to").replaceAll("[^0-9+*#]", "");
        String body = m.optString("body");
        boolean ok = false;
        String err = null;
        if (!to.isEmpty() && !body.isEmpty()) {
            try {
                android.telephony.SmsManager sm = getSystemService(android.telephony.SmsManager.class);
                int sub = m.optInt("sub", -1);
                if (sub >= 0) sm = sm.createForSubscriptionId(sub); // la SIM elegida en el Mac
                java.util.ArrayList<String> parts = sm.divideMessage(body);
                sm.sendMultipartTextMessage(to, null, parts, null, null);
                ok = true;
            } catch (Exception e) { err = e.getMessage(); }
        } else err = "Falta el número o el mensaje";
        try {
            JSONObject r = new JSONObject().put("t", "smsSent").put("ok", ok).put("to", to);
            if (err != null) r.put("err", err);
            send(r);
        } catch (Exception ignored) {}
    }

    /** SIMs activas del celular, para elegir por cuál sale el SMS escrito en el Mac. */
    private void sendSims() {
        try {
            org.json.JSONArray list = new org.json.JSONArray();
            android.telephony.SubscriptionManager subs = getSystemService(android.telephony.SubscriptionManager.class);
            java.util.List<android.telephony.SubscriptionInfo> infos = subs.getActiveSubscriptionInfoList();
            if (infos != null) for (android.telephony.SubscriptionInfo i : infos) {
                String carrier = String.valueOf(i.getCarrierName());
                String name = String.valueOf(i.getDisplayName());
                list.put(new JSONObject().put("id", i.getSubscriptionId()).put("slot", i.getSimSlotIndex() + 1)
                        .put("name", name).put("carrier", carrier));
            }
            send(new JSONObject().put("t", "sims").put("list", list)
                    .put("def", android.telephony.SubscriptionManager.getDefaultSmsSubscriptionId()));
        } catch (Exception e) {
            try { send(new JSONObject().put("t", "sims").put("list", new org.json.JSONArray()).put("err", String.valueOf(e))); } catch (Exception ignored) {}
        }
    }

    // ---------- No molestar ----------

    @Override
    public void onInterruptionFilterChanged(int filter) { sendDnd(filter); }

    private void sendDnd(int filter) {
        try { send(new JSONObject().put("t", "dnd").put("on", filter > INTERRUPTION_FILTER_ALL)); } catch (Exception ignored) {}
    }

    /** Para "Abrir en el Mac": false si no hay conexión con el Mac. */
    boolean connectedToMac() { return out != null; }

    boolean sendToMac(JSONObject m) {
        if (out == null) return false;
        send(m);
        return true;
    }

    /** Siempre fuera del hilo principal (Android prohíbe usar la red ahí). */
    private void send(JSONObject m) {
        worker.execute(() -> sendNow(m));
    }

    private void sendNow(JSONObject m) {
        OutputStream os = out;
        if (os == null) return;
        byte[] b = (m.toString() + "\n").getBytes(StandardCharsets.UTF_8);
        try { synchronized (os) { os.write(b); os.flush(); } }
        catch (Exception e) { android.util.Log.w("Puente", "send", e); }
    }

    // ---------- notificaciones ----------

    @Override
    public void onNotificationPosted(StatusBarNotification sbn, RankingMap ranking) {
        worker.execute(() -> {
            try { handlePosted(sbn, ranking); } catch (Throwable e) { android.util.Log.w("Puente", "notif", e); }
        });
    }

    /** Aviso del sistema "Se conectó la depuración inalámbrica" (no bloqueable en Ajustes). */
    private static final int NOTE_ADB_WIFI_ACTIVE = 62;
    private static final long HIDE_MS = 30L * 24 * 60 * 60 * 1000;

    private boolean hideSystemNoise(StatusBarNotification sbn) {
        if (!"android".equals(sbn.getPackageName()) || sbn.getId() != NOTE_ADB_WIFI_ACTIVE
                || !"DEVELOPER_IMPORTANT".equals(sbn.getNotification().getChannelId())) return false;
        // Posponerla la saca del panel y de la barra; si vuelve a aparecer, se pospone otra vez
        try { snoozeNotification(sbn.getKey(), HIDE_MS); } catch (Exception ignored) {}
        return true;
    }

    private void handlePosted(StatusBarNotification sbn, RankingMap rankingMap) throws Exception {
        if (hideSystemNoise(sbn)) return;
        String pkg = sbn.getPackageName();
        Notification n = sbn.getNotification();
        if (EXCLUDED.contains(pkg)) return;
        if ((n.flags & Notification.FLAG_GROUP_SUMMARY) != 0) return;
        Bundle ex = n.extras;
        if (ex.containsKey(Notification.EXTRA_MEDIA_SESSION)) return; // reproductores

        boolean call = Notification.CATEGORY_CALL.equals(n.category);
        boolean incomingCall = call && n.fullScreenIntent != null;
        if (call && !incomingCall) { removed(sbn.getKey()); return; } // llamada contestada / en curso
        if (!incomingCall && (n.flags & Notification.FLAG_ONGOING_EVENT) != 0) return;
        if (!incomingCall && (n.flags & Notification.FLAG_FOREGROUND_SERVICE) != 0) return;

        Ranking r = new Ranking();
        if (rankingMap != null && rankingMap.getRanking(sbn.getKey(), r)
                && r.getImportance() < NotificationManager.IMPORTANCE_DEFAULT && !incomingCall) return; // silenciosas

        String title = str(ex.getCharSequence(Notification.EXTRA_TITLE_BIG));
        if (title.isEmpty()) title = str(ex.getCharSequence(Notification.EXTRA_TITLE));
        String text = str(ex.getCharSequence(Notification.EXTRA_BIG_TEXT));
        if (text.isEmpty()) text = str(ex.getCharSequence(Notification.EXTRA_TEXT));
        if (text.isEmpty()) {
            CharSequence[] lines = ex.getCharSequenceArray(Notification.EXTRA_TEXT_LINES);
            if (lines != null && lines.length > 0) text = str(lines[lines.length - 1]);
        }
        if (title.isEmpty() && text.isEmpty()) return;

        // Actualizaciones sin cambios (o que no deben volver a sonar): no repetir
        String sig = title + "\u0000" + text;
        synchronized (active) {
            if (sig.equals(sentSig.get(sbn.getKey()))) { active.put(sbn.getKey(), sbn); return; }
            if (sentSig.containsKey(sbn.getKey()) && (n.flags & Notification.FLAG_ONLY_ALERT_ONCE) != 0) {
                active.put(sbn.getKey(), sbn); return;
            }
            active.put(sbn.getKey(), sbn);
            sentSig.put(sbn.getKey(), sig);
        }

        JSONObject m = new JSONObject()
                .put("t", incomingCall ? "call" : "notif")
                .put("key", sbn.getKey())
                .put("pkg", pkg)
                .put("app", appName(pkg))
                .put("title", title)
                .put("text", text)
                .put("sub", str(ex.getCharSequence(Notification.EXTRA_SUB_TEXT)))
                .put("when", sbn.getPostTime());
        JSONArray acts = new JSONArray(), inputs = new JSONArray();
        if (n.actions != null) for (int i = 0; i < n.actions.length; i++) {
            Notification.Action a = n.actions[i];
            boolean input = a.getRemoteInputs() != null && a.getRemoteInputs().length > 0;
            acts.put(str(a.title));
            if (input) inputs.put(i); // "Responder": en el Mac se muestra un cuadro de texto
        }
        m.put("actions", acts).put("inputs", inputs);
        String icon = appIcon(pkg);
        if (icon != null) m.put("icon", icon);
        Icon large = n.getLargeIcon();
        if (large != null) {
            String li = iconToPng(large.loadDrawable(this), 160);
            if (li != null) m.put("image", li);
        }
        send(m);
    }

    @Override
    public void onNotificationRemoved(StatusBarNotification sbn) {
        worker.execute(() -> removed(sbn.getKey()));
    }

    private void removed(String key) {
        boolean was;
        synchronized (active) { active.remove(key); was = sentSig.remove(key) != null; }
        if (!was) return;
        try { send(new JSONObject().put("t", "notifRemoved").put("key", key)); } catch (Exception ignored) {}
    }

    // ---------- utilidades ----------

    private static String str(CharSequence cs) { return cs == null ? "" : cs.toString().trim(); }

    private String appName(String pkg) {
        try {
            PackageManager pm = getPackageManager();
            ApplicationInfo ai = pm.getApplicationInfo(pkg, 0);
            return pm.getApplicationLabel(ai).toString();
        } catch (Exception e) { return pkg; }
    }

    private String appIcon(String pkg) {
        String c = iconCache.get(pkg);
        if (c != null) return c.isEmpty() ? null : c;
        String b64 = null;
        try { b64 = iconToPng(getPackageManager().getApplicationIcon(pkg), 128); } catch (Exception ignored) {}
        iconCache.put(pkg, b64 == null ? "" : b64);
        return b64;
    }

    private static String iconToPng(Drawable d, int size) {
        if (d == null) return null;
        Bitmap bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(bmp);
        d.setBounds(0, 0, size, size);
        d.draw(c);
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        bmp.compress(Bitmap.CompressFormat.PNG, 100, bos);
        return Base64.encodeToString(bos.toByteArray(), Base64.NO_WRAP);
    }
}
