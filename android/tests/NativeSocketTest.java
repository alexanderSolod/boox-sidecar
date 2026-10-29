package local.boox.sidecar;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.*;
import java.security.cert.X509Certificate;
import java.util.concurrent.*;
import javax.net.ssl.*;

public final class NativeSocketTest {
    private static final String TOKEN = "a".repeat(64);
    private static final String FRAME = "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nX-Frame-ID: 7\r\nX-Capture-Session: socket-session\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc";
    private static int checks;

    public static void main(String[] args) throws Exception {
        String pin = pin(args[0]);
        accepted(args[0], pin);
        accepted(args[2], pin);
        rejected(args[0], "0".repeat(64));
        rejected(args[1], pin(args[1]));
        rejected(args[3], pin);
        try (Peer peer = new Peer(args[0], "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")) {
            fails(() -> client(peer, pin).frame(0));
        }
        try (Peer peer = new Peer(args[0], FRAME.replace("Content-Length: 3", "Content-Length: 12582913"))) {
            fails(() -> client(peer, pin).frame(0));
        }
        try (Peer peer = new Peer(args[0], FRAME.replace("X-Capture-Session: socket-session\r\n", ""))) {
            fails(() -> client(peer, pin).frame(0));
        }
        try (ServerSocket trap = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
            ExecutorService executor = Executors.newSingleThreadExecutor();
            try {
                Future<byte[]> observed = executor.submit(() -> {
                    try (Socket socket = trap.accept()) {
                        socket.setSoTimeout(1500);
                        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                        byte[] chunk = new byte[2048];
                        try {
                            int count;
                            while (bytes.size() < 8192 && (count = socket.getInputStream().read(chunk)) != -1) bytes.write(chunk, 0, count);
                        } catch (SocketTimeoutException expected) { }
                        return bytes.toByteArray();
                    }
                });
                PinnedClient client = new PinnedClient("https://127.0.0.1:" + trap.getLocalPort(), TOKEN, pin);
                client.setTimeouts(1000, 1000);
                fails(() -> client.frame(0));
                byte[] bytes = observed.get(3, TimeUnit.SECONDS);
                String wire = new String(bytes, StandardCharsets.ISO_8859_1);
                check(bytes.length >= 5 && bytes[0] == 22 && !wire.contains(TOKEN) && !wire.contains("Authorization"),
                        "Plaintext trap must receive TLS handshake, not HTTP authorization");
            } finally { executor.shutdownNow(); }
        }
        try (Peer peer = new Peer(args[0], null)) {
            PinnedClient client = client(peer, pin);
            ExecutorService worker = Executors.newSingleThreadExecutor();
            try {
                Future<?> request = worker.submit(() -> {
                    try { client.frame(0); throw new AssertionError("Cancelled request succeeded"); }
                    catch (IOException expected) { }
                    catch (Exception error) { throw new RuntimeException(error); }
                });
                check(peer.received.await(3, TimeUnit.SECONDS), "Request reached delayed server");
                client.cancel();
                request.get(4, TimeUnit.SECONDS);
                fails(() -> client.frame(1));
            } finally { worker.shutdownNow(); }
        }
        System.out.println("PASS: " + checks + " real TLS, renewal, rejection, bounds and cancellation checks");
    }

    private static void accepted(String identity, String pin) throws Exception {
        try (Peer peer = new Peer(identity, FRAME)) {
            PinnedClient.Response frame = client(peer, pin).frame(0);
            check(frame.frameID == 7 && frame.captureSession.equals("socket-session") && frame.bytes.length == 3, "Authenticated frame");
            check(peer.result.get(3, TimeUnit.SECONDS).contains("Authorization: Bearer " + TOKEN), "Credential sent to authenticated peer");
        }
    }

    private static void rejected(String identity, String pin) throws Exception {
        try (Peer peer = new Peer(identity, FRAME)) {
            fails(() -> client(peer, pin).frame(0));
            check(peer.result.get(3, TimeUnit.SECONDS).isEmpty(), "Rejected peer receives no HTTP credentials");
        }
    }

    private static PinnedClient client(Peer peer, String pin) throws Exception {
        PinnedClient client = new PinnedClient("https://127.0.0.1:" + peer.server.getLocalPort(), TOKEN, pin);
        client.setTimeouts(1000, 1500);
        return client;
    }

    private static KeyStore store(String path) throws Exception {
        KeyStore store = KeyStore.getInstance("PKCS12");
        try (InputStream input = Files.newInputStream(Path.of(path))) { store.load(input, "testpass".toCharArray()); }
        return store;
    }

    private static String pin(String path) throws Exception {
        return java.util.HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                .digest(((X509Certificate) store(path).getCertificate("test")).getPublicKey().getEncoded()));
    }

    private static final class Peer implements AutoCloseable {
        final SSLServerSocket server;
        final ExecutorService worker = Executors.newSingleThreadExecutor();
        final CountDownLatch received = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        final Future<String> result;
        volatile Socket socket;

        Peer(String identity, String reply) throws Exception {
            KeyManagerFactory keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
            keys.init(store(identity), "testpass".toCharArray());
            SSLContext context = SSLContext.getInstance("TLS");
            context.init(keys.getKeyManagers(), null, null);
            server = (SSLServerSocket) context.getServerSocketFactory().createServerSocket(0, 1, InetAddress.getLoopbackAddress());
            result = worker.submit(() -> {
                StringBuilder request = new StringBuilder();
                try (Socket accepted = server.accept()) {
                    socket = accepted;
                    accepted.setSoTimeout(2500);
                    BufferedReader input = new BufferedReader(new InputStreamReader(accepted.getInputStream(), StandardCharsets.US_ASCII));
                    String line;
                    while ((line = input.readLine()) != null && !line.isEmpty()) request.append(line).append('\n');
                    received.countDown();
                    if (reply != null) {
                        accepted.getOutputStream().write(reply.getBytes(StandardCharsets.US_ASCII));
                        accepted.getOutputStream().flush();
                    } else { release.await(5, TimeUnit.SECONDS); }
                } catch (IOException expected) { }
                return request.toString();
            });
        }

        @Override public void close() throws Exception {
            release.countDown();
            server.close();
            if (socket != null) socket.close();
            worker.shutdownNow();
            if (!worker.awaitTermination(3, TimeUnit.SECONDS)) throw new AssertionError("Peer did not terminate");
        }
    }

    interface Action { void run() throws Exception; }
    private static void fails(Action action) throws Exception {
        try { action.run(); } catch (IOException expected) { checks++; return; }
        throw new AssertionError("Request unexpectedly succeeded");
    }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
        checks++;
    }
}
