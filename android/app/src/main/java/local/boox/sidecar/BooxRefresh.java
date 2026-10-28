package local.boox.sidecar;

import android.view.View;
import java.lang.reflect.Method;

/** Optional public API probes only; no hidden-API bypass or guessed waveform integers. */
final class BooxRefresh {
    private Method invalidate;
    private Object gc;
    private Method getMode;
    private Method setMode;
    private Method serviceReady;
    private int[] modeValues;
    static final String[] MODE_NAMES = {"Normal", "DU", "A2", "Regal", "X", "Regal Plus"};

    BooxRefresh() {
        try {
            Class<?> controller = Class.forName("com.onyx.android.sdk.api.device.epd.EpdController");
            Class<?> mode = Class.forName("com.onyx.android.sdk.api.device.epd.UpdateMode");
            Object candidate = mode.getField("GC").get(null);
            Method method = controller.getMethod("invalidate", View.class, mode);
            if (java.lang.reflect.Modifier.isStatic(method.getModifiers())) {
                invalidate = method;
                gc = candidate;
            }
        } catch (ReflectiveOperationException | LinkageError | SecurityException ignored) { }
        try {
            // These exact public SDK/TEST-API members were checked on Note Air4 C firmware.
            Class<?> helper = Class.forName("android.onyx.optimization.EInkHelper");
            Class<?> constants = Class.forName("android.onyx.optimization.Constant");
            getMode = helper.getMethod("getAppScopeRefreshMode");
            setMode = helper.getMethod("setAppScopeRefreshMode", int.class);
            serviceReady = helper.getMethod("isServiceReady");
            String[] fields = {"UPDATE_MODE_NORMAL", "UPDATE_MODE_DU", "UPDATE_MODE_A2", "UPDATE_MODE_REGAL", "UPDATE_MODE_X", "UPDATE_MODE_REGAL_PLUS"};
            modeValues = new int[fields.length];
            for (int i = 0; i < fields.length; i++) modeValues[i] = constants.getField(fields[i]).getInt(null);
        } catch (ReflectiveOperationException | LinkageError | SecurityException ignored) {
            getMode = null; setMode = null; serviceReady = null; modeValues = null;
        }
    }

    boolean available() { return invalidate != null; }
    boolean modesAvailable() {
        if (getMode == null || setMode == null || serviceReady == null) return false;
        try { return Boolean.TRUE.equals(serviceReady.invoke(null)); }
        catch (ReflectiveOperationException | LinkageError | SecurityException ignored) { return false; }
    }
    int currentModeIndex() {
        if (!modesAvailable()) return -1;
        try {
            int value = (Integer) getMode.invoke(null);
            for (int i = 0; i < modeValues.length; i++) if (modeValues[i] == value) return i;
        } catch (ReflectiveOperationException | LinkageError | SecurityException ignored) { }
        return -1;
    }
    boolean requestMode(int index) {
        if (!modesAvailable() || index < 0 || index >= modeValues.length) return false;
        try { setMode.invoke(null, modeValues[index]); return true; }
        catch (ReflectiveOperationException | LinkageError | SecurityException ignored) { return false; }
    }
    boolean request(View target) {
        if (!available()) return false;
        try { invalidate.invoke(null, target, gc); return true; }
        catch (ReflectiveOperationException | LinkageError | SecurityException ignored) {
            invalidate = null; gc = null; return false;
        }
    }
}
