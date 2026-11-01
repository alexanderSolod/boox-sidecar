package local.boox.sidecar;

import java.io.InputStream;
import java.io.ByteArrayInputStream;
import java.net.URL;
import java.net.URLConnection;
import java.net.URLStreamHandler;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.HostnameVerifier;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;

/** Runs the same pin/endpoint implementation as Android using the project-local JDK. */
public final class NativeClientTest {
    private static int checks;
    private static final String TOKEN = "a".repeat(64);
    public static void main(String[] args) throws Exception {
        String[] rejected = {
            "http://192.168.1.1:8787", "http://localhost:8787", "http://127.0.0.1:80",
            "http://127.0.0.1:8787", "ftp://127.0.0.1:8787", "http://user@127.0.0.1:8787",
            "http://127.0.0.1:8787/?token=x", "http://127.0.0.1:8787/#token=x",
            "https://192.168.1.1:8788/api/status", "http://127.0.0.1:8787.evil.example"
        };
        for (String endpoint : rejected) expectFailure(() -> PinnedClient.validateEndpoint(endpoint));
        check("https://127.0.0.1:8787".equals(PinnedClient.validateEndpoint("https://127.0.0.1:8787/")));
        check("https://127.0.0.1:4443".equals(PinnedClient.validateEndpoint("https://127.0.0.1:4443/")));
        expectFailure(() -> PinnedClient.validateEndpoint("https://127.0.0.1:65536"));
        expectFailure(() -> PinnedClient.validateEndpoint("https://127.0.0.1:0"));
        expectFailure(() -> PinnedClient.validateEndpoint("https://127.0.0.1"));
        check("https://192.168.1.2:8788".equals(PinnedClient.validateEndpoint("https://192.168.1.2:8788")));
        expectFailure(() -> new PinnedClient("http://127.0.0.1:8787", "bad", ""));
        expectFailure(() -> new PinnedClient("https://192.168.1.2:8788", TOKEN, ""));
        X509Certificate valid = certificate(args[0]);
        X509Certificate expired = certificate(args[1]);
        String validPin = hex(MessageDigest.getInstance("SHA-256").digest(valid.getPublicKey().getEncoded()));
        PinnedClient matched = new PinnedClient("https://192.168.1.2:8788", TOKEN, validPin);
        verify(matched, valid);
        checks++;
        PinnedClient mismatched = new PinnedClient("https://192.168.1.2:8788", TOKEN, "0".repeat(64));
        expectFailure(() -> verify(mismatched, valid));
        String expiredPin = hex(MessageDigest.getInstance("SHA-256").digest(expired.getPublicKey().getEncoded()));
        PinnedClient old = new PinnedClient("https://192.168.1.2:8788", TOKEN, expiredPin);
        expectFailure(() -> verify(old, expired));
        check(PinnedClient.normalizePin("AB:CD EF").equals("abcdef"));
        routePolicyChecks(validPin);
        captureSessionChecks();
        verifierReuseChecks(matched, valid);
        pairingStoreChecks(validPin);
        matched.cancel();
        expectFailure(() -> matched.frame(0));
        System.out.println(checks + " native endpoint/token/certificate/route/keepalive/pairing checks passed.");
    }
    static void pairingStoreChecks(String pin) throws Exception {
        String usb = "https://127.0.0.1:8787", wifi = "https://192.168.1.2:8788", host = "f".repeat(64);
        Preferences preferences = new Preferences();
        PairingStore.save(preferences, PairingStore.validate(usb, usb, wifi, TOKEN, pin, host, "auto"), true);
        preferences.edit().putString("connectionMode", "wifi").commit();
        PairingStore.save(preferences, PairingStore.validate(usb, usb, "", TOKEN, pin, host, null), true);
        check(wifi.equals(preferences.getString("wifiHost", "")));
        check("wifi".equals(preferences.getString("connectionMode", "")));
        PairingStore.save(preferences, PairingStore.validate(usb, usb, "", TOKEN, pin, host, "usb"), true);
        check("usb".equals(preferences.getString("connectionMode", "")));
        PairingStore.save(preferences, PairingStore.validate(usb, usb, "", TOKEN, pin, host, "usb"), false);
        check("".equals(preferences.getString("wifiHost", "x")));
        check("usb".equals(preferences.getString("connectionMode", "")));
        PairingStore.save(preferences, PairingStore.validate(usb, usb, wifi, TOKEN, pin, host, "wifi"), false);
        PairingStore.save(preferences, PairingStore.validate(usb, usb, "", TOKEN, pin, host, "wifi"), false);
        check("auto".equals(preferences.getString("connectionMode", "")));
        PairingStore.save(preferences, PairingStore.validate(usb, usb, wifi, TOKEN, pin, host, "wifi"), false);
        PairingStore.save(preferences, PairingStore.validate(usb, usb, "", TOKEN, pin, "e".repeat(64), null), true);
        check("".equals(preferences.getString("wifiHost", "x")));
        check("auto".equals(preferences.getString("connectionMode", "")));
        expectFailure(() -> PairingStore.validate(usb, usb, "", TOKEN, pin, host, "lan"));
    }
    static final class Preferences implements android.content.SharedPreferences {
        final java.util.Map<String, Object> values = new java.util.HashMap<>();
        @Override public java.util.Map<String, ?> getAll() { return new java.util.HashMap<>(values); }
        @Override public String getString(String key, String fallback) { return values.containsKey(key) ? (String) values.get(key) : fallback; }
        @Override public java.util.Set<String> getStringSet(String key, java.util.Set<String> fallback) { return fallback; }
        @Override public int getInt(String key, int fallback) { return values.containsKey(key) ? (Integer) values.get(key) : fallback; }
        @Override public long getLong(String key, long fallback) { return fallback; }
        @Override public float getFloat(String key, float fallback) { return fallback; }
        @Override public boolean getBoolean(String key, boolean fallback) { return fallback; }
        @Override public boolean contains(String key) { return values.containsKey(key); }
        @Override public void registerOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener) { }
        @Override public void unregisterOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener) { }
        @Override public Editor edit() {
            java.util.Map<String, Object> pending = new java.util.HashMap<>(values);
            return new Editor() {
                @Override public Editor putString(String key, String value) { pending.put(key, value); return this; }
                @Override public Editor putStringSet(String key, java.util.Set<String> value) { return this; }
                @Override public Editor putInt(String key, int value) { pending.put(key, value); return this; }
                @Override public Editor putLong(String key, long value) { return this; }
                @Override public Editor putFloat(String key, float value) { return this; }
                @Override public Editor putBoolean(String key, boolean value) { return this; }
                @Override public Editor remove(String key) { pending.remove(key); return this; }
                @Override public Editor clear() { pending.clear(); return this; }
                @Override public boolean commit() { values.clear(); values.putAll(pending); return true; }
                @Override public void apply() { commit(); }
            };
        }
    }
    static void routePolicyChecks(String identity) {
        String usb = AutoRoutePolicy.USB;
        String oldWifi = "https://192.168.1.2:8788";
        String newWifi = "https://192.168.1.3:8788";
        check(AutoRoutePolicy.candidates("auto", usb, oldWifi, newWifi).equals(java.util.List.of(usb, newWifi, oldWifi)));
        check(AutoRoutePolicy.candidates("auto", usb, oldWifi, oldWifi).equals(java.util.List.of(usb, oldWifi)));
        check(AutoRoutePolicy.candidates("usb", usb, oldWifi, newWifi).equals(java.util.List.of(usb)));
        check(AutoRoutePolicy.candidates("wifi", usb, oldWifi, newWifi).equals(java.util.List.of(newWifi, oldWifi)));
        check(AutoRoutePolicy.candidates("auto", usb, "http://192.168.1.2:8787", "http://evil.invalid:443").equals(java.util.List.of(usb)));
        check(AutoRoutePolicy.identityMatches(identity, identity));
        check(!AutoRoutePolicy.identityMatches(identity, "0".repeat(64)));
        check(!AutoRoutePolicy.identityMatches("", ""));
        check(!AutoRoutePolicy.identityMatches(identity, null));
        check(AutoRoutePolicy.retryDelay(0) == 500);
        check(AutoRoutePolicy.retryDelay(1) == 1000);
        check(AutoRoutePolicy.retryDelay(20) == 8000);
        check(AutoRoutePolicy.shouldProbeUsb("auto", newWifi, usb, 10000, 10000));
        check(!AutoRoutePolicy.shouldProbeUsb("auto", newWifi, usb, 9999, 10000));
        check(!AutoRoutePolicy.shouldProbeUsb("wifi", newWifi, usb, 20000, 10000));
        check(!AutoRoutePolicy.shouldProbeUsb("auto", usb, usb, 20000, 10000));
    }
    static void captureSessionChecks() {
        CaptureSessionState authority = new CaptureSessionState();
        check(!authority.accepts(""));
        check(authority.update("first-session", true));
        check(authority.accepts("first-session"));
        check(!authority.update("first-session", true));
        check(authority.update("second-session", true));
        check(!authority.accepts("first-session"));
        check(authority.accepts("second-session"));
        check(authority.update("second-session", false));
        check(!authority.accepts("second-session"));
        check(!authority.update("", true));
        check(!authority.accepts(""));
        check(!CaptureSessionState.valid("bad\r\nheader"));
    }
    static void verifierReuseChecks(PinnedClient client, X509Certificate valid) throws Exception {
        java.util.ArrayList<FakeHttps> opened = new java.util.ArrayList<>();
        URL.setURLStreamHandlerFactory(protocol -> "https".equals(protocol) ? new URLStreamHandler() {
            @Override protected URLConnection openConnection(URL url) {
                FakeHttps connection = new FakeHttps(url);
                opened.add(connection);
                return connection;
            }
        } : null);
        check("test-session".equals(client.frame(0).captureSession));
        client.frame(1);
        check(opened.size() == 2);
        HostnameVerifier first = opened.get(0).getHostnameVerifier();
        check(first == opened.get(1).getHostnameVerifier());
        check(opened.get(0).getSSLSocketFactory() == opened.get(1).getSSLSocketFactory());
        javax.net.ssl.SSLSession session = (javax.net.ssl.SSLSession) java.lang.reflect.Proxy.newProxyInstance(
                NativeClientTest.class.getClassLoader(), new Class[]{javax.net.ssl.SSLSession.class},
                (proxy, method, args) -> {
                    if (method.getName().equals("getPeerCertificates")) return new java.security.cert.Certificate[]{valid};
                    throw new UnsupportedOperationException();
                });
        check(first.verify("192.168.1.2", session));
        check(!first.verify("attacker.invalid", session));
        FakeHttps.captureSessionHeader = null;
        expectFailure(() -> client.frame(2));
        FakeHttps.captureSessionHeader = "bad\r\nheader";
        expectFailure(() -> client.frame(2));
        FakeHttps.captureSessionHeader = "test-session";
    }
    static final class FakeHttps extends HttpsURLConnection {
        static String captureSessionHeader = "test-session";
        FakeHttps(URL url) { super(url); }
        @Override public void connect() { }
        @Override public void disconnect() { }
        @Override public boolean usingProxy() { return false; }
        @Override public String getCipherSuite() { return "test"; }
        @Override public java.security.cert.Certificate[] getLocalCertificates() { return null; }
        @Override public java.security.cert.Certificate[] getServerCertificates() { return null; }
        @Override public int getResponseCode() { return 200; }
        @Override public String getHeaderField(String key) { return "X-Frame-ID".equals(key) ? "1" : "X-Capture-Session".equals(key) ? captureSessionHeader : null; }
        @Override public String getContentType() { return "image/jpeg"; }
        @Override public int getContentLength() { return 3; }
        @Override public InputStream getInputStream() { return new ByteArrayInputStream(new byte[]{1, 2, 3}); }
    }
    static X509Certificate certificate(String filename) throws Exception {
        KeyStore store = KeyStore.getInstance("PKCS12");
        try (InputStream in = Files.newInputStream(Path.of(filename))) { store.load(in, "testpass".toCharArray()); }
        return (X509Certificate) store.getCertificate("test");
    }
    static void verify(PinnedClient client, X509Certificate certificate) throws Exception {
        Method verify = PinnedClient.class.getDeclaredMethod("verifyCertificate", X509Certificate[].class);
        verify.setAccessible(true);
        try { verify.invoke(client, (Object) new X509Certificate[]{certificate}); }
        catch (InvocationTargetException exception) {
            if (exception.getCause() instanceof CertificateException) throw (CertificateException) exception.getCause();
            throw exception;
        }
    }
    static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder();
        for (byte value : bytes) out.append(String.format("%02x", value & 0xff));
        return out.toString();
    }
    interface Action { void run() throws Exception; }
    static void expectFailure(Action action) throws Exception {
        try { action.run(); } catch (java.io.IOException | java.security.cert.CertificateException expected) { checks++; return; }
        throw new AssertionError("Expected validation failure");
    }
    static void check(boolean value) { if (!value) throw new AssertionError(); checks++; }
}
