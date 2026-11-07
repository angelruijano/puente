package cl.hazlo.puente;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.util.Patterns;
import android.widget.Toast;

import org.json.JSONObject;

import java.util.regex.Matcher;

/** "Enviar al Mac" en el menú Compartir: archivos a Descargas del Mac; links y texto se abren o copian allá. */
public final class ShareActivity extends Activity {
    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        Intent i = getIntent();
        java.util.List<android.net.Uri> files = streams(i);
        if (!files.isEmpty()) { sendFiles(files); return; }
        CharSequence cs = i.getCharSequenceExtra(Intent.EXTRA_TEXT);
        String text = cs == null ? "" : cs.toString().trim();
        if (text.isEmpty() && i.getData() != null) text = i.getData().toString();
        String url = null;
        Matcher m = Patterns.WEB_URL.matcher(text);
        while (m.find()) {
            String u = m.group();
            if (u.startsWith("http://") || u.startsWith("https://")) { url = u; break; }
            if (url == null) url = u;
        }
        if (url != null && !url.startsWith("http")) url = "https://" + url;
        boolean ok = false;
        try {
            JSONObject msg = new JSONObject().put("t", "openOnMac");
            if (url != null) msg.put("url", url); else msg.put("text", text);
            String subject = i.getStringExtra(Intent.EXTRA_SUBJECT);
            if (subject != null) msg.put("title", subject);
            NotifListener l = NotifListener.instance;
            ok = !text.isEmpty() && l != null && l.sendToMac(msg);
        } catch (Exception ignored) {}
        Toast.makeText(this, ok ? (url != null ? "Abriendo en tu Mac" : "Copiado en tu Mac")
                : "Tu Mac no está conectado", Toast.LENGTH_SHORT).show();
        finish();
    }

    private static java.util.List<android.net.Uri> streams(Intent i) {
        java.util.List<android.net.Uri> out = new java.util.ArrayList<>();
        if (Intent.ACTION_SEND_MULTIPLE.equals(i.getAction())) {
            java.util.ArrayList<android.net.Uri> l = i.getParcelableArrayListExtra(Intent.EXTRA_STREAM, android.net.Uri.class);
            if (l != null) out.addAll(l);
        } else {
            android.net.Uri u = i.getParcelableExtra(Intent.EXTRA_STREAM, android.net.Uri.class);
            if (u != null) out.add(u);
        }
        return out;
    }

    /** La ventana (transparente) sigue viva mientras se copian: así no se pierde el permiso de leerlos. */
    private void sendFiles(java.util.List<android.net.Uri> files) {
        if (NotifListener.instance == null || !NotifListener.instance.connectedToMac()) {
            Toast.makeText(this, "Tu Mac no está conectado", Toast.LENGTH_SHORT).show();
            finish();
            return;
        }
        Toast.makeText(this, files.size() == 1 ? "Enviando a tu Mac…" : "Enviando " + files.size() + " archivos a tu Mac…",
                Toast.LENGTH_SHORT).show();
        Files.sendToMac(this, files, () -> runOnUiThread(() ->
                Toast.makeText(getApplicationContext(), "No se pudo enviar a tu Mac", Toast.LENGTH_SHORT).show()),
                () -> runOnUiThread(this::finish));
    }
}
