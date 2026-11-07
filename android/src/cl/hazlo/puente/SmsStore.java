package cl.hazlo.puente;

import android.content.Context;
import android.database.ContentObserver;
import android.database.Cursor;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.function.Consumer;

/** Historial de SMS para la ventana de Mensajes del Mac (solo lectura; Android guarda lo enviado). */
final class SmsStore {
    private static final Uri SMS = Uri.parse("content://sms");
    private static final String[] COLS = {"_id", "thread_id", "address", "body", "date", "type", "read", "sub_id", "status"};

    private final Context ctx;
    private final Handler main = new Handler(Looper.getMainLooper());
    private ContentObserver observer;

    SmsStore(Context ctx) { this.ctx = ctx; }

    /** Avisa al Mac cuando llega, se envía o se borra un SMS (agrupado para no inundar). */
    void watch(Consumer<JSONObject> send) {
        if (observer != null) return;
        Runnable notify = () -> { try { send.accept(new JSONObject().put("t", "smsChanged")); } catch (Exception ignored) {} };
        observer = new ContentObserver(main) {
            @Override public void onChange(boolean self) { main.removeCallbacks(notify); main.postDelayed(notify, 700); }
        };
        try { ctx.getContentResolver().registerContentObserver(SMS, true, observer); } catch (Exception ignored) {}
    }

    void unwatch() {
        if (observer != null) ctx.getContentResolver().unregisterContentObserver(observer);
        observer = null;
    }

    /** Conversaciones, la más reciente primero, con el último mensaje y cuántos sin leer. */
    JSONObject threads() throws Exception {
        Map<Long, JSONObject> byThread = new LinkedHashMap<>();
        try (Cursor c = ctx.getContentResolver().query(SMS, COLS, null, null, "date DESC LIMIT 5000")) {
            while (c != null && c.moveToNext()) {
                long tid = c.getLong(1);
                JSONObject t = byThread.get(tid);
                if (t == null) {
                    if (byThread.size() >= 300) continue;
                    t = new JSONObject().put("id", tid).put("addr", str(c, 2)).put("snippet", str(c, 3))
                            .put("date", c.getLong(4)).put("out", c.getInt(5) != 1).put("sub", c.getInt(7)).put("unread", 0);
                    byThread.put(tid, t);
                }
                if (c.getInt(5) == 1 && c.getInt(6) == 0) t.put("unread", t.getInt("unread") + 1);
            }
        }
        JSONArray list = new JSONArray();
        for (JSONObject t : byThread.values()) list.put(t);
        return new JSONObject().put("t", "smsThreads").put("list", list);
    }

    /** Mensajes de una conversación, del más antiguo al más nuevo. */
    JSONObject thread(long tid, int limit) throws Exception {
        JSONArray msgs = new JSONArray();
        String addr = "";
        try (Cursor c = ctx.getContentResolver().query(SMS, COLS, "thread_id=?", new String[]{String.valueOf(tid)},
                "date DESC LIMIT " + Math.max(20, Math.min(limit, 1000)))) {
            while (c != null && c.moveToNext()) {
                if (addr.isEmpty()) addr = str(c, 2);
                int type = c.getInt(5); // 1 recibido, 2 enviado, 4 saliendo, 5 falló, 6 en cola
                msgs.put(new JSONObject().put("id", c.getLong(0)).put("body", str(c, 3)).put("date", c.getLong(4))
                        .put("out", type != 1).put("sub", c.getInt(7))
                        .put("state", type == 5 ? "failed" : (type == 4 || type == 6) ? "sending" : "ok"));
            }
        }
        JSONArray asc = new JSONArray();
        for (int i = msgs.length() - 1; i >= 0; i--) asc.put(msgs.get(i));
        return new JSONObject().put("t", "smsThread").put("id", tid).put("addr", addr).put("msgs", asc);
    }

    private static String str(Cursor c, int i) { String s = c.getString(i); return s == null ? "" : s; }
}
