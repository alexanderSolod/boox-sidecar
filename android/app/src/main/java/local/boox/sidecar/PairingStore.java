package local.boox.sidecar;

import android.content.Intent;
import android.content.SharedPreferences;
import java.io.IOException;
import java.util.Map;

final class PairingStore {
    private static final String[] KEYS = {"token", "hostId", "usbHost", "wifiHost", "wifiPin", "connectionMode"};

    static Record fromIntent(Intent intent) throws Exception {
        if (intent == null) throw new IOException("Missing pairing details.");
        return validate(intent.getStringExtra("host"), intent.getStringExtra("token"),
                intent.getStringExtra("cert_sha256"), intent.getStringExtra("host_id"));
    }

    static Record validate(String endpoint, String token, String fingerprint, String identity) throws Exception {
        String host = PinnedClient.validateEndpoint(endpoint);
        String pin = PinnedClient.normalizePin(fingerprint);
        String hostId = PinnedClient.normalizePin(identity);
        if (hostId.isEmpty()) hostId = pin;
        if (!hostId.matches("[0-9a-f]{64}") || (host.startsWith("https:") && !hostId.equals(pin)))
            throw new IOException("Provision the Mac's matching host identity and certificate pin.");
        new PinnedClient(host, token, pin);
        return new Record(host, token, pin, hostId);
    }

    static void save(SharedPreferences preferences, Record record) throws IOException {
        Map<String, ?> before = preferences.getAll();
        String previousId = preferences.getString("hostId", preferences.getString("wifiPin", ""));
        SharedPreferences.Editor editor = preferences.edit();
        if (!record.hostId.equals(previousId)) editor.remove("wifiHost").remove("wifiPin");
        editor.putString("token", record.token).putString("hostId", record.hostId)
                .putString("usbHost", AutoRoutePolicy.USB).putString("connectionMode", "auto");
        if (record.host.startsWith("https:")) editor.putString("wifiHost", record.host).putString("wifiPin", record.pin);
        if (!editor.commit()) {
            SharedPreferences.Editor restore = preferences.edit();
            for (String key : KEYS) {
                Object value = before.get(key);
                if (value instanceof String) restore.putString(key, (String) value);
                else restore.remove(key);
            }
            restore.commit();
            throw new IOException("Could not save pairing. Existing pairing was retained.");
        }
    }

    static final class Record {
        final String host;
        final String token;
        final String pin;
        final String hostId;

        Record(String host, String token, String pin, String hostId) {
            this.host = host;
            this.token = token;
            this.pin = pin;
            this.hostId = hostId;
        }
    }
}
