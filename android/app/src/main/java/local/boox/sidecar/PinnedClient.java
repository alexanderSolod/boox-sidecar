package local.boox.sidecar;

import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.security.MessageDigest;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;
import java.util.Locale;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.HostnameVerifier;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

/** Session-scoped TLS pinning. No process-global TLS or hostname overrides. */
final class PinnedClient {
    static final int MAX_FRAME_BYTES = 12 * 1024 * 1024;
    private final String endpoint;
    private final String token;
    private final String pin;
    private final SSLSocketFactory sockets;
    private final HostnameVerifier hostnameVerifier;
    private int connectTimeout = 2500;
    private int readTimeout = 3500;
    private volatile HttpURLConnection active;
    private volatile boolean cancelled;

    PinnedClient(String endpoint, String token, String fingerprint) throws Exception {
        this.endpoint = validateEndpoint(endpoint);
        if (token == null || !token.matches("[0-9a-fA-F]{64}")) {
            throw new IOException("Enter the 64-character session token shown on your Mac.");
        }
        this.token = token;
        this.pin = normalizePin(fingerprint);
        final String expectedHost = new URI(this.endpoint).getHost();
        // Android's connection pool compares verifier identity, so reuse one per client.
        hostnameVerifier = (hostname, session) -> {
            try {
                java.security.cert.Certificate[] peer = session.getPeerCertificates();
                if (peer.length == 0 || !(peer[0] instanceof X509Certificate)) return false;
                verifyCertificate(new X509Certificate[]{(X509Certificate) peer[0]});
                return expectedHost.equalsIgnoreCase(hostname);
            } catch (Exception exception) { return false; }
        };
        if (this.endpoint.startsWith("https:")) {
            if (!pin.matches("[0-9a-f]{64}")) throw new IOException("Wi-Fi requires the Mac certificate SHA-256 pin.");
            SSLContext context = SSLContext.getInstance("TLS");
            context.init(null, new TrustManager[]{new X509TrustManager() {
                @Override public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
                @Override public void checkClientTrusted(X509Certificate[] chain, String authType) throws CertificateException {
                    throw new CertificateException("Client certificates are not used.");
                }
                @Override public void checkServerTrusted(X509Certificate[] chain, String authType) throws CertificateException {
                    verifyCertificate(chain);
                }
            }}, null);
            sockets = context.getSocketFactory();
        } else sockets = null;
    }

    static String normalizePin(String input) {
        return input == null ? "" : input.replace(":", "").replace(" ", "").trim().toLowerCase(Locale.ROOT);
    }

    static String validateEndpoint(String input) throws IOException {
        try {
            URI uri = new URI(input == null ? "" : input.trim());
            boolean loopback = "http".equals(uri.getScheme()) && "127.0.0.1".equals(uri.getHost()) && uri.getPort() == 8787;
            boolean tls = "https".equals(uri.getScheme()) && uri.getHost() != null && !uri.getHost().isEmpty() && uri.getPort() == 8788;
            if ((!loopback && !tls) || uri.getUserInfo() != null || uri.getQuery() != null || uri.getFragment() != null
                    || !(uri.getPath().isEmpty() || "/".equals(uri.getPath()))) throw new IOException("Invalid host");
            return new URI(uri.getScheme(), null, uri.getHost(), uri.getPort(), null, null, null).toString();
        } catch (Exception exception) {
            throw new IOException("Use http://127.0.0.1:8787 for USB or https://MAC_IP:8788 for Wi-Fi.");
        }
    }

    private void verifyCertificate(X509Certificate[] chain) throws CertificateException {
        if (chain == null || chain.length == 0) throw new CertificateException("Missing server certificate.");
        chain[0].checkValidity();
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(chain[0].getEncoded());
            byte[] expected = new byte[32];
            for (int i = 0; i < expected.length; i++) expected[i] = (byte) Integer.parseInt(pin.substring(i * 2, i * 2 + 2), 16);
            if (!MessageDigest.isEqual(digest, expected)) throw new CertificateException("Mac certificate pin mismatch.");
        } catch (CertificateException exception) { throw exception; }
        catch (Exception exception) { throw new CertificateException("Cannot verify Mac certificate.", exception); }
    }

    JSONObject json(String path, JSONObject body) throws Exception {
        Response response = request(path, body, 65536);
        return new JSONObject(new String(response.bytes, java.nio.charset.StandardCharsets.UTF_8));
    }

    void setTimeouts(int connectMillis, int readMillis) {
        connectTimeout = connectMillis;
        readTimeout = readMillis;
    }

    Response frame(long after) throws Exception {
        return request("/api/frame?after=" + after, null, MAX_FRAME_BYTES);
    }

    private Response request(String path, JSONObject body, int limit) throws Exception {
        if (cancelled) throw new IOException("Session stopped.");
        HttpURLConnection connection = (HttpURLConnection) new URL(endpoint + path).openConnection();
        active = connection;
        if (cancelled) { connection.disconnect(); throw new IOException("Session stopped."); }
        boolean reusable = false;
        try {
            connection.setConnectTimeout(connectTimeout);
            connection.setReadTimeout(readTimeout);
            connection.setInstanceFollowRedirects(false);
            connection.setUseCaches(false);
            connection.setRequestProperty("Authorization", "Bearer " + token);
            connection.setRequestProperty("Accept", path.startsWith("/api/frame") ? "image/jpeg" : "application/json");
            if (connection instanceof HttpsURLConnection) {
                HttpsURLConnection tls = (HttpsURLConnection) connection;
                tls.setSSLSocketFactory(sockets);
                // A provisioned exact leaf pin is the server identity; recheck it here too.
                tls.setHostnameVerifier(hostnameVerifier);
            }
            if (body != null) {
                byte[] payload = body.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8);
                connection.setRequestMethod("POST");
                connection.setRequestProperty("Content-Type", "application/json");
                connection.setDoOutput(true);
                connection.setFixedLengthStreamingMode(payload.length);
                try (java.io.OutputStream output = connection.getOutputStream()) { output.write(payload); }
            }
            int status = connection.getResponseCode();
            if (status == 401) throw new IOException("Session token expired or incorrect. Re-pair with the Mac.");
            if (status == 403) throw new IOException("Remote input needs Mac-side approval and Accessibility permission.");
            if (status >= 300 && status < 400) throw new IOException("Mac returned a redirect, which is not accepted.");
            if (status >= 400) throw new IOException("Mac returned HTTP " + status + ".");
            if (status == 204) {
                reusable = true;
                return new Response(new byte[0], -1);
            }
            long id = -1;
            String header = connection.getHeaderField("X-Frame-ID");
            if (header != null) { try { id = Long.parseLong(header); } catch (NumberFormatException ignored) { } }
            if (path.startsWith("/api/frame") && (id < 0 || !"image/jpeg".equalsIgnoreCase(connection.getContentType())))
                throw new IOException("Mac returned an invalid image response.");
            int declaredLength = connection.getContentLength();
            if (declaredLength > limit) throw new IOException("Mac response exceeds the size limit.");
            ByteArrayOutputStream output = new ByteArrayOutputStream(Math.max(1024, Math.min(declaredLength, limit)));
            try (InputStream stream = connection.getInputStream()) {
                byte[] chunk = new byte[16384];
                int count;
                while ((count = stream.read(chunk)) != -1) {
                    if (cancelled) throw new IOException("Session stopped.");
                    if (output.size() + count > limit) throw new IOException("Mac response exceeds the size limit.");
                    output.write(chunk, 0, count);
                }
            }
            reusable = true;
            return new Response(output.toByteArray(), id);
        } finally {
            active = null;
            // Fully consumed/closed responses return their socket to Android's keepalive pool.
            // Disconnecting every successful frame would force a TCP/TLS handshake per frame.
            if (!reusable || cancelled) connection.disconnect();
        }
    }

    void cancel() {
        cancelled = true;
        HttpURLConnection connection = active;
        if (connection != null) connection.disconnect();
    }

    static final class Response {
        final byte[] bytes;
        final long frameID;
        Response(byte[] bytes, long frameID) { this.bytes = bytes; this.frameID = frameID; }
    }
}
