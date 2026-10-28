package local.boox.sidecar;

import android.content.Intent;
import android.content.SharedPreferences;
import java.io.IOException;
import java.net.URI;
import java.util.Map;

final class PairingStore {
    private static final String[] KEYS = {"pairingVersion", "token", "hostId", "usbHost", "wifiHost", "wifiPin", "spkiPin", "connectionMode"};

    static Record fromIntent(Intent intent) throws Exception {
        if (intent == null || intent.getIntExtra("pairing_version", 0) != 2)
            throw new IOException("Update both apps and pair over USB again.");
        return validate(intent.getStringExtra("host"), intent.getStringExtra("usb_host"),
                intent.getStringExtra("wifi_host"), intent.getStringExtra("token"),
                intent.getStringExtra("spki_sha256"), intent.getStringExtra("host_id"),
                intent.getStringExtra("preferred_transport"));
    }

    static Record validate(String endpoint, String usbEndpoint, String wifiEndpoint, String token,
                           String fingerprint, String identity, String preference) throws Exception {
        String host = PinnedClient.validateEndpoint(endpoint);
        String usb = PinnedClient.validateEndpoint(usbEndpoint);
        if (!"127.0.0.1".equals(new URI(usb).getHost())) throw new IOException("USB requires the tablet loopback endpoint.");
        String wifi = wifiEndpoint == null || wifiEndpoint.isEmpty() ? "" : PinnedClient.validateEndpoint(wifiEndpoint);
        if (!host.equals(usb) && wifi.isEmpty()) wifi = host;
        if (!host.equals(usb) && !host.equals(wifi)) throw new IOException("The primary route must match USB or Wi-Fi.");
        if (wifi.equals(usb)) throw new IOException("Wi-Fi must use a separate endpoint.");
        String pin = PinnedClient.normalizePin(fingerprint);
        String hostId = PinnedClient.normalizePin(identity);
        if (!hostId.matches("[0-9a-f]{64}")) throw new IOException("Provision the Mac installation identity.");
        String mode = preference == null || preference.isEmpty() ? "auto" : preference;
        if (!"auto".equals(mode) && !"usb".equals(mode) && !"wifi".equals(mode)) throw new IOException("Invalid transport preference.");
        new PinnedClient(usb, token, pin);
        if (!wifi.isEmpty()) new PinnedClient(wifi, token, pin);
        return new Record(host, usb, wifi, token, pin, hostId, mode);
    }

    static Record load(SharedPreferences preferences) throws Exception {
        if (preferences.getInt("pairingVersion", 0) != 2)
            throw new IOException("Update both apps, connect USB, and press Connect on the Mac to pair again.");
        String usb = preferences.getString("usbHost", "");
        return validate(usb, usb, preferences.getString("wifiHost", ""), preferences.getString("token", ""),
                preferences.getString("spkiPin", ""), preferences.getString("hostId", ""),
                preferences.getString("connectionMode", "auto"));
    }

    static void save(SharedPreferences preferences, Record record) throws IOException {
        Map<String, ?> before = preferences.getAll();
        String wifi = record.wifi;
        if (wifi.isEmpty() && record.hostId.equals(preferences.getString("hostId", ""))
                && record.pin.equals(preferences.getString("spkiPin", ""))) {
            wifi = preferences.getString("wifiHost", "");
        }
        SharedPreferences.Editor editor = preferences.edit();
        editor.putInt("pairingVersion", 2).putString("token", record.token).putString("hostId", record.hostId)
                .putString("usbHost", record.usb).putString("wifiHost", wifi).putString("spkiPin", record.pin)
                .putString("connectionMode", record.mode).remove("wifiPin");
        if (!editor.commit()) {
            SharedPreferences.Editor restore = preferences.edit();
            for (String key : KEYS) {
                Object value = before.get(key);
                if (value instanceof String) restore.putString(key, (String) value);
                else if (value instanceof Integer) restore.putInt(key, (Integer) value);
                else restore.remove(key);
            }
            restore.commit();
            throw new IOException("Could not save pairing. Existing pairing was retained.");
        }
    }

    static final class Record {
        final String host, usb, wifi, token, pin, hostId, mode;
        Record(String host, String usb, String wifi, String token, String pin, String hostId, String mode) {
            this.host = host;
            this.usb = usb;
            this.wifi = wifi;
            this.token = token;
            this.pin = pin;
            this.hostId = hostId;
            this.mode = mode;
        }
    }
}
