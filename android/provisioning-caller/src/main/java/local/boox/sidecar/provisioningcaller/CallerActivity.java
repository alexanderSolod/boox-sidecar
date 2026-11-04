package local.boox.sidecar.provisioningcaller;

import android.app.Activity;
import android.content.Intent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.os.Bundle;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

public final class CallerActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        Intent attempt = new Intent().setClassName("local.boox.sidecar.acceptance", "local.boox.sidecar.ProvisioningReceiver")
                .putExtra("pairing_version", 2)
                .putExtra("host", "https://127.0.0.1:9")
                .putExtra("usb_host", "https://127.0.0.1:9")
                .putExtra("token", repeated('d'))
                .putExtra("spki_sha256", repeated('e'))
                .putExtra("host_id", repeated('f'));
        final int untouched = 867;
        try {
            sendOrderedBroadcast(attempt, null, new BroadcastReceiver() {
                @Override public void onReceive(Context context, Intent intent) {
                    recordResult(getResultCode() == untouched ? "DENIED" : "ALLOWED");
                }
            }, null, untouched, null, null);
        } catch (SecurityException expected) { recordResult("DENIED"); }
    }

    private void recordResult(String result) {
        try (FileOutputStream output = openFileOutput("result", MODE_PRIVATE)) {
            output.write(result.getBytes(StandardCharsets.US_ASCII));
        } catch (Exception error) { throw new IllegalStateException(error); }
        finish();
    }

    private static String repeated(char value) {
        char[] chars = new char[64];
        java.util.Arrays.fill(chars, value);
        return new String(chars);
    }
}
