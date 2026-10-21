package org.rpggodo.android;

import android.app.Activity;
import android.content.Context;
import android.content.pm.ActivityInfo;
import android.hardware.display.DisplayManager;
import android.os.Handler;
import android.os.Looper;
import android.view.Display;
import android.view.View;
import org.json.JSONObject;
import java.util.function.Consumer;

/** App-local orientation requests and actual render-view geometry, including
 * 180-degree turns that do not resize the view. No refresh-rate policy. */
final class DisplayPreferences implements DisplayManager.DisplayListener {
    private final Activity activity;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final DisplayManager displays;
    private final Consumer<String> changed;
    private final View view;
    private boolean destroyed;
    private String last = "";
    private int lastRotation = -1, lastWidth, lastHeight;
    private final View.OnLayoutChangeListener layout = (v, l, t, r, b, ol, ot, or, ob) -> publish();

    DisplayPreferences(Activity activity, View view, Consumer<String> changed) {
        this.activity = activity;
        this.view = view;
        this.changed = changed;
        displays = (DisplayManager) activity.getSystemService(Context.DISPLAY_SERVICE);
        displays.registerDisplayListener(this, handler);
        view.addOnLayoutChangeListener(layout);
    }

    void setOrientation(int mode) {
        handler.post(() -> {
            if (destroyed || mode < 0 || mode > 4) return;
            int[] modes = {ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE,
                ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE,
                ActivityInfo.SCREEN_ORIENTATION_PORTRAIT,
                ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT,
                ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR};
            activity.setRequestedOrientation(modes[mode]);
        });
    }

    void requestState() { handler.post(() -> { last = ""; publish(); }); }

    private void publish() {
        if (destroyed || view.getWidth() <= 0 || view.getHeight() <= 0) return;
        Display display = view.getDisplay();
        if (display == null) return;
        int rotation = display.getRotation();
        if (lastRotation >= 0 && ((rotation - lastRotation) & 1) != 0
                && view.getWidth() == lastWidth && view.getHeight() == lastHeight) {
            // DisplayListener can precede the renderer's 90-degree layout.
            // Wait for that layout; a 180-degree change needs no resize.
            return;
        }
        // App UI uses this full render view plus user-calibrated margins. Do not
        // retain transient system-bar/cutout insets sampled during screen unlock.
        try {
            JSONObject state = new JSONObject();
            state.put("rotation", rotation);
            state.put("width", view.getWidth());
            state.put("height", view.getHeight());
            String next = state.toString();
            lastRotation = rotation;
            lastWidth = view.getWidth();
            lastHeight = view.getHeight();
            if (!next.equals(last)) { last = next; changed.accept(next); }
        } catch (org.json.JSONException impossible) { throw new IllegalStateException(impossible); }
    }

    void destroy() {
        destroyed = true;
        displays.unregisterDisplayListener(this);
        view.removeOnLayoutChangeListener(layout);
        handler.removeCallbacksAndMessages(null);
    }
    @Override public void onDisplayAdded(int id) { publish(); }
    @Override public void onDisplayRemoved(int id) { publish(); }
    @Override public void onDisplayChanged(int id) { publish(); }
}
