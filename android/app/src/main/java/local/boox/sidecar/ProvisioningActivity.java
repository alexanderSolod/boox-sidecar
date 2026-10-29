package local.boox.sidecar;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.widget.Toast;

public final class ProvisioningActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        try {
            PairingStore.Record record = PairingStore.fromIntent(getIntent());
            PairingStore.save(getSharedPreferences("pairing", MODE_PRIVATE), record, true);
            Intent launcher = new Intent(this, MainActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            startActivity(launcher);
        } catch (Exception exception) {
            Toast.makeText(this, "Pairing rejected. Check the Mac pairing details and try again.", Toast.LENGTH_LONG).show();
        } finally {
            setIntent(new Intent());
            finish();
        }
    }
}
