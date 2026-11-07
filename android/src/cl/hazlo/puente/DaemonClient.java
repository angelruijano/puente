package cl.hazlo.puente;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;

/** Habla con el proceso residente (usuario shell) por 127.0.0.1, con el token que dejó el ayudante. */
final class DaemonClient {
    private DaemonClient() {}

    /** Respuesta del residente, o null si no corre o no tenemos el token. Bloquea: no llamar en el hilo principal. */
    static JSONObject ask(Context c, String cmd) {
        SharedPreferences p = c.getSharedPreferences("link", Context.MODE_PRIVATE);
        int port = p.getInt("daemonPort", 0);
        String token = p.getString("daemonToken", null);
        if (port == 0 || token == null) return null;
        try (Socket s = new Socket(InetAddress.getByName("127.0.0.1"), port)) {
            s.setSoTimeout(15000);
            OutputStream o = s.getOutputStream();
            o.write((token + "\n" + cmd + "\n").getBytes(StandardCharsets.UTF_8));
            o.flush();
            String l = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8)).readLine();
            return l == null ? null : new JSONObject(l);
        } catch (Exception e) {
            return null;
        }
    }
}
