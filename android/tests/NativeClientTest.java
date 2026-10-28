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
        verifierReuseChecks(matched, valid);
        matched.cancel();
        expectFailure(() -> matched.frame(0));
        System.out.println(checks + " native endpoint/token/certificate/route/keepalive checks passed.");
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
    static void verifierReuseChecks(PinnedClient client, X509Certificate valid) throws Exception {
        java.util.ArrayList<FakeHttps> opened = new java.util.ArrayList<>();
        URL.setURLStreamHandlerFactory(protocol -> "https".equals(protocol) ? new URLStreamHandler() {
            @Override protected URLConnection openConnection(URL url) {
                FakeHttps connection = new FakeHttps(url);
                opened.add(connection);
                return connection;
            }
        } : null);
        client.frame(0);
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
    }
    static final class FakeHttps extends HttpsURLConnection {
        FakeHttps(URL url) { super(url); }
        @Override public void connect() { }
        @Override public void disconnect() { }
        @Override public boolean usingProxy() { return false; }
        @Override public String getCipherSuite() { return "test"; }
        @Override public java.security.cert.Certificate[] getLocalCertificates() { return null; }
        @Override public java.security.cert.Certificate[] getServerCertificates() { return null; }
        @Override public int getResponseCode() { return 200; }
        @Override public String getHeaderField(String key) { return "X-Frame-ID".equals(key) ? "1" : null; }
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
