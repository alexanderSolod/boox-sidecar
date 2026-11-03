package local.boox.sidecar;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** ADB-only (DUMP permission) refresh-mode control: am broadcast -n local.boox.sidecar/.RefreshReceiver --es mode x */
public final class RefreshReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        BooxRefresh refresh = new BooxRefresh();
        String name = intent == null ? null : intent.getStringExtra("mode");
        if (name == null || name.trim().isEmpty()) {
            int current = refresh.currentModeIndex();
            setResultCode(current >= 0 ? Activity.RESULT_OK : Activity.RESULT_CANCELED);
            setResultData(current >= 0 ? BooxRefresh.MODE_NAMES[current] : "Refresh modes unavailable");
            return;
        }
        int index = -1;
        String normalized = name.trim().replace(" ", "");
        for (int i = 0; i < BooxRefresh.MODE_NAMES.length; i++) {
            if (BooxRefresh.MODE_NAMES[i].replace(" ", "").equalsIgnoreCase(normalized)) { index = i; break; }
        }
        if (index >= 0 && refresh.requestMode(index)) {
            setResultCode(Activity.RESULT_OK);
            setResultData(BooxRefresh.MODE_NAMES[index]);
        } else {
            setResultCode(Activity.RESULT_CANCELED);
            setResultData(index < 0 ? "Unknown mode; use normal|du|a2|regal|x|regal plus" : "Mode unavailable on this firmware");
        }
    }
}
