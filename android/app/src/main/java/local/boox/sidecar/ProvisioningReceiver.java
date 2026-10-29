package local.boox.sidecar;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public final class ProvisioningReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        try {
            PairingStore.Record record = PairingStore.fromIntent(intent);
            PairingStore.save(context.getSharedPreferences("pairing", Context.MODE_PRIVATE), record, true);
            setResultCode(Activity.RESULT_OK);
        } catch (Exception exception) {
            setResultCode(Activity.RESULT_CANCELED);
            setResultData(exception.getMessage());
        }
    }
}
