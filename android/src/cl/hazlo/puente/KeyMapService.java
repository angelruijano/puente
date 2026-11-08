package cl.hazlo.puente;

import android.accessibilityservice.AccessibilityService;
import android.content.ComponentName;
import android.media.session.MediaController;
import android.media.session.MediaSessionManager;
import android.media.session.PlaybackState;
import android.os.SystemClock;
import android.view.KeyEvent;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;

import java.util.List;
import java.util.Set;

/**
 * Atajos de teclado para reproductores, con el teclado del Mac (scrcpy --keyboard=uhid) o cualquier teclado físico.
 * Si la app que está al frente es la que está reproduciendo (tiene la sesión multimedia):
 *   ← / →  retrocede / adelanta SEEK_MS
 *   espacio  pausa / reanuda
 * No toca nada mientras escribes en un campo de texto, ni en apps sin reproductor.
 * Se activa en Ajustes → Accesibilidad → Aplicaciones instaladas → Puente.
 */
public class KeyMapService extends AccessibilityService {
    private static final long SEEK_MS = 10_000;
    /** Apps donde NO se aplican los atajos (por ejemplo, si ya tienen los suyos y los prefieres). */
    private static final Set<String> EXCLUDED = Set.of();
    /** Paquetes que se ponen "al frente" sin ser la app que estás usando. */
    private static final Set<String> OVERLAYS = Set.of("com.android.systemui", "com.samsung.android.honeyboard",
            "com.google.android.inputmethod.latin", "cl.hazlo.puente");

    private volatile String foreground = "";

    @Override public void onAccessibilityEvent(AccessibilityEvent e) {
        if (e.getEventType() != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED || e.getPackageName() == null) return;
        String pkg = e.getPackageName().toString();
        if (!OVERLAYS.contains(pkg)) foreground = pkg;
    }

    @Override public void onInterrupt() {}

    @Override protected boolean onKeyEvent(KeyEvent ev) {
        int code = ev.getKeyCode();
        if (code != KeyEvent.KEYCODE_DPAD_LEFT && code != KeyEvent.KEYCODE_DPAD_RIGHT && code != KeyEvent.KEYCODE_SPACE) return false;
        if (ev.hasModifiers(KeyEvent.META_SHIFT_ON) || ev.isCtrlPressed() || ev.isAltPressed() || ev.isMetaPressed()) return false;
        if (EXCLUDED.contains(foreground) || typing()) return false;
        MediaController mc = controllerFor(foreground);
        if (mc == null) return false;
        PlaybackState st = mc.getPlaybackState();
        if (st == null) return false;
        long actions = st.getActions();
        boolean handled;
        if (code == KeyEvent.KEYCODE_SPACE) {
            handled = (actions & (PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE | PlaybackState.ACTION_PLAY_PAUSE)) != 0;
            if (handled && ev.getAction() == KeyEvent.ACTION_DOWN && ev.getRepeatCount() == 0) {
                if (st.getState() == PlaybackState.STATE_PLAYING) mc.getTransportControls().pause();
                else mc.getTransportControls().play();
            }
        } else {
            boolean fwd = code == KeyEvent.KEYCODE_DPAD_RIGHT;
            boolean canSeek = (actions & PlaybackState.ACTION_SEEK_TO) != 0;
            long fallback = fwd ? PlaybackState.ACTION_FAST_FORWARD : PlaybackState.ACTION_REWIND;
            handled = canSeek || (actions & fallback) != 0;
            if (handled && ev.getAction() == KeyEvent.ACTION_DOWN) {
                if (canSeek) {
                    long pos = position(st) + (fwd ? SEEK_MS : -SEEK_MS);
                    long dur = mc.getMetadata() != null
                            ? mc.getMetadata().getLong(android.media.MediaMetadata.METADATA_KEY_DURATION) : 0;
                    if (dur > 0) pos = Math.min(pos, dur - 1000);
                    mc.getTransportControls().seekTo(Math.max(0, pos));
                } else if (fwd) mc.getTransportControls().fastForward();
                else mc.getTransportControls().rewind();
            }
        }
        return handled; // se consume la tecla (bajada y subida) solo si la usamos
    }

    /** Posición actual estimada (la que reporta la sesión puede tener unos segundos). */
    private static long position(PlaybackState st) {
        long pos = st.getPosition();
        if (st.getState() == PlaybackState.STATE_PLAYING && st.getLastPositionUpdateTime() > 0) {
            pos += (long) ((SystemClock.elapsedRealtime() - st.getLastPositionUpdateTime()) * st.getPlaybackSpeed());
        }
        return pos;
    }

    private MediaController controllerFor(String pkg) {
        if (pkg.isEmpty()) return null;
        try {
            MediaSessionManager msm = getSystemService(MediaSessionManager.class);
            List<MediaController> list = msm.getActiveSessions(new ComponentName(this, NotifListener.class));
            for (MediaController mc : list) if (pkg.equals(mc.getPackageName())) return mc;
        } catch (SecurityException ignored) {} // sin acceso a notificaciones no hay sesiones
        return null;
    }

    /** true si el foco está en un campo de texto: ahí las flechas y el espacio son para escribir. */
    private boolean typing() {
        AccessibilityNodeInfo root = getRootInActiveWindow();
        if (root == null) return false;
        AccessibilityNodeInfo f = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
        return f != null && f.isEditable();
    }
}
