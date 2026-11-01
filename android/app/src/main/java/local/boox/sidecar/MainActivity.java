package local.boox.sidecar;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.os.Build;
import android.os.PowerManager;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.Settings;
import android.text.InputType;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import org.json.JSONObject;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** Native JPEG receiver with one network/decode worker and at most one pending UI frame. */
public final class MainActivity extends Activity {
    private static final String USB = AutoRoutePolicy.USB;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final ScheduledThreadPoolExecutor worker = new ScheduledThreadPoolExecutor(1);
    private final SessionRouter router = new SessionRouter(worker);
    private final SessionCoordinator<PinnedClient> sessions = new SessionCoordinator<>();
    private final AtomicReference<JSONObject> pendingInput = new AtomicReference<>();
    private final AtomicReference<JSONObject> pendingSettings = new AtomicReference<>();
    private final AtomicReference<PendingFrame> pendingFrame = new AtomicReference<>();
    private final BooxRefresh refresh = new BooxRefresh();
    private SharedPreferences preferences;
    private FrameView frameView;
    private FrameLayout root;
    private LinearLayout controls;
    private TextView status;
    private Button toggle;
    private Button refreshButton;
    private volatile boolean resumed;
    private volatile int fps = 60;
    private volatile boolean color = true;
    private volatile int maxWidth = 1240;
    private volatile double jpegQuality = 0.70;
    private volatile String routeEndpoint = "";
    private volatile String discoveredEndpoint = "";
    private long lastConnectRequest;
    private MacDiscovery discovery;
    private ConnectivityManager connectivity;
    private PowerManager powerManager;
    private PowerManager.WakeLock cpuLock;
    private PowerManager.WakeLock screenLock;
    private ConnectivityManager.NetworkCallback networkCallback;
    private BroadcastReceiver powerReceiver;
    private CheckBox colorControl;
    private boolean updatingControls;
    private volatile PinnedClient client;
    private boolean remoteInputRequested;
    private boolean fullscreen = true;
    private long lastFrameID = -1;
    private long nextStatusAt;
    private long measurementStart;
    private int receivedFrames;
    private String hostStatus = "";
    private boolean framePosted;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        worker.setRemoveOnCancelPolicy(true);
        preferences = getSharedPreferences("pairing", MODE_PRIVATE);
        fps = preferences.getInt("fps", 60);
        fps = Math.max(1, Math.min(60, fps));
        color = preferences.getBoolean("color", true);
        maxWidth = preferences.getInt("maxWidth", 1240);
        jpegQuality = Math.max(0.4, Math.min(0.95, preferences.getFloat("jpegQuality", 0.70f)));
        discovery = new MacDiscovery(this);
        connectivity = (ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
        powerManager = (PowerManager) getSystemService(POWER_SERVICE);
        maxWidth = Math.max(600, Math.min(2480, maxWidth));
        buildUi();
        setFullscreen(true);
        Log.i("BooxSidecar", "Native receiver ready; full-refresh API " + (refresh.available() ? "available" : "unavailable"));
        Log.i("BooxSidecar", "BOOX refresh mode ready=" + refresh.modesAvailable() + " index=" + refresh.currentModeIndex());
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(new Intent());
        discoveredEndpoint = "";
        if (resumed) startSession();
    }

    private String savedHostId() {
        return preferences.getString("hostId", "");
    }

    private void buildUi() {
        root = new FrameLayout(this);
        root.setBackgroundColor(Color.WHITE);
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                    insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets;
        });
        frameView = new FrameView(this);
        root.addView(frameView, new FrameLayout.LayoutParams(-1, -1));
        controls = new LinearLayout(this);
        controls.setOrientation(LinearLayout.VERTICAL);
        controls.setPadding(dp(12), dp(8), dp(12), dp(8));
        controls.setBackgroundColor(Color.WHITE);
        status = new TextView(this);
        status.setTextColor(Color.BLACK);
        status.setTextSize(16);
        status.setText("Connect to your saved Mac. USB and Wi-Fi switch automatically.");
        controls.addView(status);
        LinearLayout first = row();
        first.addView(button("Connect", this::startSession));
        first.addView(button("Advanced pairing…", this::showConnectionDialog));
        first.addView(button("Connection: Auto / USB / Wi-Fi", this::showRouteModes));
        first.addView(button("Fullscreen", () -> setFullscreen(!fullscreen)));
        refreshButton = button(refresh.available() ? "Full refresh" : "E Ink Center…", this::requestRefresh);
        first.addView(refreshButton);
        first.addView(button("BOOX refresh mode…", this::showRefreshModes));
        first.addView(button("Faster panel…", this::showFastPanel));
        controls.addView(scrolling(first));
        LinearLayout second = row();
        TextView rateLabel = new TextView(this);
        rateLabel.setText("Stream FPS: ");
        second.addView(rateLabel);
        for (int rate : new int[]{5, 15, 30, 60}) {
            second.addView(button(Integer.toString(rate), () -> {
                fps = rate;
                preferences.edit().putInt("fps", fps).apply();
                queueSettings();
                Toast.makeText(this, "Requested " + fps + " FPS; panel refresh may be lower.", Toast.LENGTH_SHORT).show();
            }));
        }
        CheckBox colorToggle = new CheckBox(this);
        colorControl = colorToggle;
        colorToggle.setText("Color");
        colorToggle.setChecked(color);
        colorToggle.setOnCheckedChangeListener((button, checked) -> {
            if (updatingControls) return;
            color = checked;
            preferences.edit().putBoolean("color", color).apply();
            queueSettings();
        });
        second.addView(colorToggle);
        CheckBox inputToggle = new CheckBox(this);
        inputToggle.setText("Remote input");
        inputToggle.setOnCheckedChangeListener((button, checked) -> {
            remoteInputRequested = checked;
            updateFrameInput();
        });
        second.addView(inputToggle);
        controls.addView(scrolling(second));
        LinearLayout profiles = row();
        profiles.addView(button("Speed", () -> applyProfile(1240, true, 0.60)));
        profiles.addView(button("Balanced color", () -> applyProfile(1240, true, 0.78)));
        profiles.addView(button("Sharp text", () -> applyProfile(2480, false, 0.88)));
        controls.addView(scrolling(profiles));
        LinearLayout third = row();
        TextView widthLabel = new TextView(this);
        widthLabel.setText("Max width: ");
        third.addView(widthLabel);
        for (int width : new int[]{1240, 1860, 2480}) {
            third.addView(button(Integer.toString(width), () -> {
                maxWidth = width;
                preferences.edit().putInt("maxWidth", width).apply();
                queueSettings();
            }));
        }
        third.addView(button("Clear saved pairing", () -> new AlertDialog.Builder(this)
                .setMessage("Remove the saved Mac token and Wi-Fi certificate pin from this device?")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Clear", (dialog, which) -> {
                    stopSession();
                    discovery.stop();
                    discoveredEndpoint = "";
                    preferences.edit().remove("token").remove("wifiPin").remove("wifiHost").remove("usbHost")
                            .remove("hostId").remove("wifi").remove("connectionMode").remove("pairingVersion").remove("spkiPin").apply();
                    frameView.clearFrame();
                    status.setText("Saved pairing removed. Connect once by USB and press Connect on your Mac.");
                }).show()));
        controls.addView(scrolling(third));
        ScrollView panel = new ScrollView(this);
        panel.setFillViewport(false);
        panel.addView(controls);
        FrameLayout.LayoutParams panelParams = new FrameLayout.LayoutParams(-1, -2, Gravity.TOP);
        panelParams.topMargin = dp(52);
        root.addView(panel, panelParams);
        controls.setVisibility(View.GONE);
        toggle = button("Controls", () -> controls.setVisibility(controls.getVisibility() == View.VISIBLE ? View.GONE : View.VISIBLE));
        root.addView(toggle, new FrameLayout.LayoutParams(-2, dp(48), Gravity.TOP | Gravity.END));
        setContentView(root);
        root.requestApplyInsets();
    }

    private void showConnectionDialog() {
        LinearLayout fields = new LinearLayout(this);
        fields.setOrientation(LinearLayout.VERTICAL);
        fields.setPadding(dp(20), dp(8), dp(20), dp(8));
        CheckBox wifi = new CheckBox(this);
        wifi.setText("Include Wi-Fi route");
        wifi.setChecked(!preferences.getString("wifiHost", "").isEmpty());
        fields.addView(wifi);
        EditText host = field(fields, "Wi-Fi Mac URL", preferences.getString("wifiHost", "https://192.168.1.100:8788"), false);
        EditText usb = field(fields, "USB HTTPS URL", preferences.getString("usbHost", USB), false);
        EditText token = field(fields, "Mac session token (64 hex characters)", preferences.getString("token", ""), true);
        EditText pin = field(fields, "Mac public-key SHA-256 pin", preferences.getString("spkiPin", ""), false);
        EditText identity = field(fields, "Mac installation identity", savedHostId(), false);
        TextView instructions = new TextView(this);
        instructions.setText("Usually you only need to connect USB once and press Connect on your Mac.\n"
                + "Auto prefers authenticated USB, then the saved Mac over pinned Wi-Fi.\n"
                + "The Mac remembers its identity and token between normal launches.\n"
                + "This advanced form is for manual setup; automatic discovery cannot pair an unknown Mac.");
        fields.addView(instructions);
        ScrollView scroll = new ScrollView(this);
        scroll.addView(fields);
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle("Connect to your Mac").setView(scroll)
                .setNegativeButton("Cancel", null).setPositiveButton("Connect", null).create();
        dialog.setOnShowListener(ignored -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(view -> {
            try {
                String usbEndpoint = usb.getText().toString().trim();
                String wifiEndpoint = wifi.isChecked() ? host.getText().toString().trim() : "";
                PairingStore.Record record = PairingStore.validate(usbEndpoint, usbEndpoint, wifiEndpoint,
                        token.getText().toString().trim(), pin.getText().toString(), identity.getText().toString(),
                        preferences.getString("connectionMode", "auto"));
                new AlertDialog.Builder(this).setTitle("Replace saved pairing?")
                        .setMessage("Trust these Mac pairing details and replace the saved connection?")
                        .setNegativeButton("Cancel", null)
                        .setPositiveButton("Replace", (confirmation, which) -> {
                            try {
                                PairingStore.save(preferences, record, false);
                                stopSession();
                                discoveredEndpoint = "";
                                dialog.dismiss();
                                startSession();
                            } catch (Exception exception) {
                                host.setError("Could not save pairing. Try again.");
                            }
                        }).show();
            } catch (Exception exception) { host.setError(exception.getMessage()); }
        }));
        dialog.show();
    }

    private void showRouteModes() {
        String current = preferences.getString("connectionMode", "auto");
        String[] values = {"auto", "usb", "wifi"};
        int selected = "usb".equals(current) ? 1 : "wifi".equals(current) ? 2 : 0;
        new AlertDialog.Builder(this).setTitle("Connection preference")
                .setSingleChoiceItems(new String[]{"Auto · USB first, then saved Wi-Fi", "USB only", "Pinned Wi-Fi only"}, selected,
                        (dialog, which) -> {
                            preferences.edit().putString("connectionMode", values[which]).apply();
                            dialog.dismiss();
                            startSession();
                        }).setNegativeButton("Cancel", null).show();
    }

    private void applyProfile(int width, boolean useColor, double quality) {
        maxWidth = width;
        color = useColor;
        jpegQuality = quality;
        fps = 60;
        preferences.edit().putInt("maxWidth", width).putBoolean("color", color)
                .putFloat("jpegQuality", (float) quality).putInt("fps", fps).apply();
        colorControl.setChecked(color);
        queueSettings();
        Toast.makeText(this, width + " px · " + (color ? "color" : "grayscale") + " · "
                + Math.round(quality * 100) + "% JPEG quality. Actual rate appears in status.", Toast.LENGTH_LONG).show();
    }

    private void startSession() {
        stopSession();
        if (!resumed) return;
        lastConnectRequest = SystemClock.elapsedRealtime();
        frameView.clearFrame();
        final int session = sessions.begin();
        try {
            SessionRouter.Pairing pairing = new SessionRouter.Pairing(PairingStore.load(preferences));
            status.setText("Connecting to your saved Mac…");
            startDiscovery();
            router.start(session, pairing, new SessionRouter.Listener() {
                @Override public boolean current(int candidate) { return isCurrent(candidate); }
                @Override public String discoveredEndpoint() { return discoveredEndpoint; }
                @Override public void selected(SessionRouter.Route route) { activateRoute(session, pairing, route); }
                @Override public void retrying(String message) { postStatus(session, null, message, true); }
            });
        } catch (Exception exception) {
            status.setText(exception.getMessage());
            controls.setVisibility(View.VISIBLE);
        }
    }

    private synchronized void activateRoute(int session, SessionRouter.Pairing pairing, SessionRouter.Route route) {
        if (!isCurrent(session) || !sessions.activate(session, route.client)) { route.client.cancel(); return; }
        PinnedClient old = client;
        client = route.client;
        routeEndpoint = route.endpoint;
        if (old != null && old != client) old.cancel();
        lastFrameID = -1;
        nextStatusAt = 0;
        measurementStart = SystemClock.elapsedRealtime();
        receivedFrames = 0;
        router.activated(session);
        pendingInput.set(null);
        PendingFrame discard = pendingFrame.getAndSet(null);
        if (discard != null) discard.bitmap.recycle();
        if (!route.endpoint.equals(pairing.usb)) preferences.edit().putString("wifiHost", route.endpoint).apply();
        Log.i("BooxSidecar", "Authenticated route connected: " + (pairing.usb.equals(route.endpoint) ? "USB" : "pinned Wi-Fi"));
        setCaptureState(session, route.client, route.status.optBoolean("permission") && route.status.optBoolean("capturing"),
                route.status.optString("capture_session", ""), route.status.optBoolean("displayAsleep", false));
        adoptHostSettings(session, route.client, route.status);
        worker.execute(() -> poll(session, pairing, route.client, route.endpoint));
    }

    private void startDiscovery() {
        if (!resumed) return;
        if (preferences.getInt("pairingVersion", 0) != 2 || "usb".equals(preferences.getString("connectionMode", "auto"))) {
            discovery.stop();
            return;
        }
        String expectedId = savedHostId();
        discovery.start(expectedId, endpoint -> {
            if (!resumed || !expectedId.equals(savedHostId())) return;
            boolean changed = !endpoint.equals(discoveredEndpoint);
            discoveredEndpoint = endpoint;
            if (changed && client == null && !sessions.hostAsleep() && SystemClock.elapsedRealtime() - lastConnectRequest > 1000) startSession();
        });
    }

    private synchronized void stopSession() {
        sessions.stop();
        updateScreenLock();
        router.stop();
        if (frameView != null) {
            frameView.clearFrame();
            updateFrameInput();
        }
        PinnedClient previous = client;
        client = null;
        routeEndpoint = "";
        if (previous != null) previous.cancel();
        pendingInput.set(null);
        pendingSettings.set(null);
        PendingFrame previousFrame = pendingFrame.getAndSet(null);
        if (previousFrame != null) previousFrame.bitmap.recycle();
        worker.getQueue().clear();
    }

    private void poll(int session, SessionRouter.Pairing pairing, PinnedClient connection, String endpoint) {
        if (!isCurrent(session) || !sessions.owns(session, connection)) return;
        SessionRouter.Route upgrade = router.takeUsbUpgrade();
        if (upgrade != null) {
            if (upgrade.session == session && "auto".equals(pairing.mode) && !sessions.hostAsleep()) {
                activateRoute(session, pairing, upgrade);
                return;
            }
            upgrade.client.cancel();
        }
        if (!sessions.hostAsleep()) router.maybeProbeUsb(session, endpoint);
        long started = SystemClock.elapsedRealtime();
        long delay = Math.max(1, 1000 / fps);
        try {
            JSONObject settings = pendingSettings.getAndSet(null);
            if (settings != null) {
                try { connection.json("/api/settings", settings); }
                catch (Exception exception) {
                    if (isCurrent(session) && sessions.owns(session, connection)) pendingSettings.compareAndSet(null, settings);
                    throw exception;
                }
            }
            if (!isCurrent(session) || !sessions.owns(session, connection)) return;
            JSONObject input = pendingInput.getAndSet(null);
            if (input != null && sessions.captureReady() && sessions.acceptsCapture(input.optString("capture_session", ""))) {
                try { connection.json("/api/input", input); }
                catch (Exception exception) { postStatus(session, connection, exception.getMessage(), true); }
            }
            if (started >= nextStatusAt) {
                JSONObject result = connection.json("/api/status", null);
                synchronized (this) {
                    if (!isCurrent(session) || !sessions.owns(session, connection)) return;
                    SessionRouter.validateHost(pairing, result);
                    adoptHostSettings(session, connection, result);
                    setCaptureState(session, connection, result.optBoolean("permission") && result.optBoolean("capturing"),
                            result.optString("capture_session", ""), result.optBoolean("displayAsleep", false));
                    if (result.optLong("frameID", 0) < lastFrameID) lastFrameID = -1;
                    hostStatus = !result.optBoolean("permission") ? "Grant Screen Recording on your Mac."
                            : sessions.hostAsleep() ? "Mac display asleep — resumes on wake"
                            : !result.optBoolean("capturing") ? "Start capture on your Mac."
                            : result.optBoolean("demo") ? "Demo frames" : "Connected";
                    nextStatusAt = started + (sessions.hostAsleep() ? 5000 : 2000);
                    double measured = receivedFrames * 1000.0 / Math.max(1, started - measurementStart);
                    postStatus(session, connection, (pairing.usb.equals(endpoint) ? "USB" : "Wi-Fi") + " · " + hostStatus + " · " + fps + " FPS requested · "
                            + String.format(java.util.Locale.ROOT, "%.1f", measured) + " FPS received · "
                            + (color ? "color" : "grayscale") + " · " + maxWidth + " px", !sessions.captureReady());
                    if (started - measurementStart >= 5000) {
                        Log.i("BooxSidecar", "Stream stats: " + String.format(java.util.Locale.ROOT, "%.1f", measured)
                                + " FPS received, " + fps + " requested, session=" + session);
                        measurementStart = started;
                        receivedFrames = 0;
                    }
                }
            }
            PinnedClient.Response response = sessions.captureReady() ? connection.frame(lastFrameID)
                    : new PinnedClient.Response(new byte[0], -1);
            if (response.bytes.length != 0 && isCurrent(session)) {
                if (!sessions.acceptsCapture(response.captureSession)) {
                    setCaptureState(session, connection, false, "", sessions.hostAsleep());
                    nextStatusAt = 0;
                    if (isCurrent(session) && sessions.owns(session, connection)) worker.schedule(() -> poll(session, pairing, connection, endpoint), 1, TimeUnit.MILLISECONDS);
                    return;
                }
                BitmapFactory.Options bounds = new BitmapFactory.Options();
                bounds.inJustDecodeBounds = true;
                BitmapFactory.decodeByteArray(response.bytes, 0, response.bytes.length, bounds);
                if (bounds.outWidth <= 0 || bounds.outHeight <= 0 || bounds.outWidth > 8192 || bounds.outHeight > 8192
                        || (long) bounds.outWidth * bounds.outHeight > 16_000_000) throw new Exception("Frame dimensions exceed the native decoder limit.");
                BitmapFactory.Options decode = new BitmapFactory.Options();
                decode.inPreferredConfig = Bitmap.Config.ARGB_8888;
                decode.inSampleSize = 1;
                while (bounds.outWidth / decode.inSampleSize > maxWidth * 2
                        || (long) (bounds.outWidth / decode.inSampleSize) * (bounds.outHeight / decode.inSampleSize) > 8_000_000)
                    decode.inSampleSize *= 2;
                Bitmap bitmap = BitmapFactory.decodeByteArray(response.bytes, 0, response.bytes.length, decode);
                if (bitmap == null) throw new Exception("The Mac sent an undecodable frame.");
                if (!isCurrent(session) || client != connection || !sessions.acceptsCapture(response.captureSession)) { bitmap.recycle(); return; }
                lastFrameID = response.frameID;
                receivedFrames++;
                PendingFrame replaced = pendingFrame.getAndSet(new PendingFrame(session, connection, response.captureSession, bitmap));
                if (replaced != null) replaced.bitmap.recycle();
                synchronized (this) {
                    if (!framePosted) {
                        framePosted = true;
                        ui.post(this::displayPendingFrame);
                    }
                }
            }
            delay = sessions.captureReady() ? Math.max(1, 1000 / fps - (SystemClock.elapsedRealtime() - started)) : (sessions.hostAsleep() ? 3000 : 500);
        } catch (Exception exception) {
            connectionFailed(session, connection, exception);
            return;
        }
        if (isCurrent(session) && sessions.owns(session, connection)) worker.schedule(() -> poll(session, pairing, connection, endpoint), delay, TimeUnit.MILLISECONDS);
    }

    private boolean isCurrent(int session) { return resumed && sessions.isCurrent(session); }

    private synchronized void connectionFailed(int session, PinnedClient connection, Exception exception) {
        if (!isCurrent(session) || !sessions.owns(session, connection)) return;
        setCaptureState(session, connection, false, "", sessions.hostAsleep());
        sessions.failed(session, connection);
        connection.cancel();
        client = null;
        routeEndpoint = "";
        ui.post(() -> {
            synchronized (MainActivity.this) {
                if (!isCurrent(session) || client != null) return;
                if (!sessions.hostAsleep()) frameView.clearFrame();
                updateFrameInput();
                updateScreenLock();
            }
        });
        postStatus(session, null, "Reconnecting · " + SessionRouter.connectionError(exception), true);
        router.reconnect(session);
    }

    private synchronized void displayPendingFrame() {
        framePosted = false;
        PendingFrame frame = pendingFrame.getAndSet(null);
        if (frame == null) return;
        if (!isCurrent(frame.session) || !sessions.captureReady() || frame.owner != client || !sessions.acceptsCapture(frame.captureSession)) frame.bitmap.recycle();
        else frameView.setFrame(frame.bitmap, frame.session, frame.captureSession);
    }

    private synchronized void setCaptureState(int session, PinnedClient owner, boolean ready, String reportedSession, boolean asleep) {
        if (!isCurrent(session) || !sessions.owns(session, owner)) return;
        boolean changed = sessions.updateCapture(session, owner, ready, reportedSession, asleep);
        if (!sessions.captureReady() || changed) {
            lastFrameID = -1;
            pendingInput.set(null);
            PendingFrame discarded = pendingFrame.getAndSet(null);
            if (discarded != null) discarded.bitmap.recycle();
        }
        String expectedCapture = sessions.captureSession();
        ui.post(() -> {
            synchronized (MainActivity.this) {
                if (!isCurrent(session) || !sessions.owns(session, owner)
                        || !sessions.captureSession().equals(expectedCapture) || sessions.hostAsleep() != asleep) return;
                if ((changed || !sessions.captureReady()) && !asleep) frameView.clearFrame();
                updateFrameInput();
                updateScreenLock();
            }
        });
    }

    private void updateFrameInput() {
        frameView.setInput(remoteInputRequested && sessions.captureReady(), new FrameView.InputListener() {
            @Override public void tap(String authority, double x, double y) { queueInput(authority, "tap", x, y); }
            @Override public void scroll(String authority, double delta) { queueInput(authority, "scroll", delta, 0); }
        });
    }

    private void postStatus(int session, PinnedClient owner, String message, boolean show) {
        ui.post(() -> {
            synchronized (MainActivity.this) {
                if (!isCurrent(session) || client != owner) return;
                status.setText(message);
                if (show) controls.setVisibility(View.VISIBLE);
            }
        });
    }

    private void queueSettings() {
        try { pendingSettings.set(new JSONObject().put("fps", fps).put("grayscale", !color).put("maxWidth", maxWidth).put("jpegQuality", jpegQuality)); }
        catch (Exception ignored) { }
    }

    private synchronized void adoptHostSettings(int session, PinnedClient owner, JSONObject result) {
        if (!isCurrent(session) || !sessions.owns(session, owner) || pendingSettings.get() != null) return;
        fps = Math.max(1, Math.min(60, result.optInt("fps", fps)));
        maxWidth = Math.max(600, Math.min(2480, result.optInt("maxWidth", maxWidth)));
        color = !result.optBoolean("grayscale", !color);
        double reportedQuality = result.optDouble("jpegQuality", jpegQuality);
        if (Double.isFinite(reportedQuality)) jpegQuality = Math.max(0.4, Math.min(0.95, reportedQuality));
        preferences.edit().putInt("fps", fps).putInt("maxWidth", maxWidth).putBoolean("color", color)
                .putFloat("jpegQuality", (float) jpegQuality).apply();
        ui.post(() -> {
            synchronized (MainActivity.this) {
                if (!isCurrent(session) || !sessions.owns(session, owner)) return;
                updatingControls = true;
                colorControl.setChecked(color);
                updatingControls = false;
            }
        });
    }

    private void queueInput(String authority, String type, double first, double second) {
        if (!sessions.captureReady() || !resumed || !sessions.acceptsCapture(authority)) return;
        try {
            JSONObject event = new JSONObject().put("type", type).put("capture_session", authority);
            if ("tap".equals(type)) event.put("x", first).put("y", second);
            else event.put("deltaY", first);
            pendingInput.set(event);
        } catch (Exception ignored) { }
    }

    private void requestRefresh() {
        if (refresh.available() && refresh.request(frameView)) {
            Toast.makeText(this, "Full refresh requested from the BOOX API.", Toast.LENGTH_SHORT).show();
            return;
        }
        refreshButton.setText("E Ink Center…");
        new AlertDialog.Builder(this).setTitle("BOOX E Ink Center")
                .setMessage("This firmware does not expose a supported full-refresh API to this app.\n\n"
                        + "Swipe down from the top-right to open BOOX Control Center, then open E Ink Center and use Full Refresh. "
                        + "Choose the app's refresh mode there. Streaming 60 FPS does not make the e-ink panel refresh at 60 Hz.\n\n"
                        + "Open system settings if you need to find the BOOX display controls.")
                .setNegativeButton("Done", null)
                .setPositiveButton("System settings", (dialog, which) -> {
                    try { startActivity(new Intent(Settings.ACTION_SETTINGS)); }
                    catch (android.content.ActivityNotFoundException ignored) { }
                }).show();
    }

    private void showRefreshModes() {
        if (!refresh.modesAvailable()) {
            requestRefresh();
            return;
        }
        new AlertDialog.Builder(this).setTitle("BOOX refresh mode · fast modes reduce detail")
                .setSingleChoiceItems(BooxRefresh.MODE_NAMES, refresh.currentModeIndex(), (dialog, selected) -> {
                    dialog.dismiss();
                    if (!resumed || !refresh.requestMode(selected)) {
                        Toast.makeText(this, "Refresh mode unavailable. Use E Ink Center.", Toast.LENGTH_LONG).show();
                        return;
                    }
                    ui.postDelayed(() -> {
                        if (!resumed || isFinishing()) return;
                        boolean confirmed = refresh.currentModeIndex() == selected;
                        Toast.makeText(this, confirmed ? "BOOX reports " + BooxRefresh.MODE_NAMES[selected] + " mode."
                                : "Mode requested but not confirmed. Check E Ink Center.", Toast.LENGTH_LONG).show();
                    }, 300);
                }).setNegativeButton("Cancel", null).show();
    }

    private void showFastPanel() {
        new AlertDialog.Builder(this).setTitle("Faster BOOX panel response")
                .setMessage("X mode can make movement feel faster, with less detail and more ghosting. "
                        + "This changes only this app's BOOX refresh mode. It does not promise a 60 Hz panel. "
                        + "Use E Ink Center for a full refresh when needed.")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Use X mode", (dialog, which) -> {
                    if (!resumed || !refresh.requestMode(4)) {
                        Toast.makeText(this, "X mode unavailable through the public API. Use E Ink Center.", Toast.LENGTH_LONG).show();
                        return;
                    }
                    ui.postDelayed(() -> {
                        if (!resumed) return;
                        Toast.makeText(this, refresh.currentModeIndex() == 4 ? "BOOX reports X mode."
                                : "X mode requested but not confirmed. Check E Ink Center.", Toast.LENGTH_LONG).show();
                    }, 300);
                }).show();
    }

    @SuppressWarnings("deprecation")
    private void setFullscreen(boolean enabled) {
        fullscreen = enabled;
        getWindow().getDecorView().setSystemUiVisibility(enabled
                ? View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                : View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR);
        root.requestApplyInsets();
    }

    @Override protected void onResume() {
        super.onResume();
        resumed = true;
        startNetworkMonitoring();
        acquireWakeLocks();
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        startSession();
    }

    @Override protected void onPause() {
        resumed = false;
        stopNetworkMonitoring();
        discovery.stop();
        stopSession();
        releaseWakeLocks();
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        super.onPause();
    }

    // FLAG_KEEP_SCREEN_ON is not honored by some Onyx builds; real wake locks
    // are. A partial lock keeps the poll worker alive if the display sleeps so
    // a Mac wake is still detected; the screen lock is dropped while the Mac
    // display sleeps so the tablet can idle down, and ACQUIRE_CAUSES_WAKEUP
    // brings it back on wake.
    @SuppressWarnings("deprecation")
    private void acquireWakeLocks() {
        if (powerManager == null) return;
        if (cpuLock == null) {
            cpuLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "boox:stream");
            cpuLock.setReferenceCounted(false);
            cpuLock.acquire();
        }
        updateScreenLock();
    }

    @SuppressWarnings("deprecation")
    private void updateScreenLock() {
        if (powerManager == null) return;
        if (resumed && !sessions.hostAsleep()) {
            if (screenLock == null || !screenLock.isHeld()) {
                releaseScreenLock();
                screenLock = powerManager.newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK
                        | PowerManager.ACQUIRE_CAUSES_WAKEUP, "boox:display");
                screenLock.setReferenceCounted(false);
                screenLock.acquire();
            }
        } else {
            releaseScreenLock();
        }
    }

    private void releaseScreenLock() {
        if (screenLock != null) {
            if (screenLock.isHeld()) screenLock.release();
            screenLock = null;
        }
    }

    private void releaseWakeLocks() {
        releaseScreenLock();
        if (cpuLock != null) {
            if (cpuLock.isHeld()) cpuLock.release();
            cpuLock = null;
        }
    }

    @Override public void onBackPressed() {
        if (controls.getVisibility() == View.VISIBLE) controls.setVisibility(View.GONE);
        else if (fullscreen) setFullscreen(false);
        else super.onBackPressed();
    }

    @Override protected void onDestroy() {
        resumed = false;
        stopSession();
        releaseWakeLocks();
        worker.shutdownNow();
        router.close();
        discovery.stop();
        frameView.clearFrame();
        super.onDestroy();
    }

    private void startNetworkMonitoring() {
        if (connectivity != null && networkCallback == null) {
            networkCallback = new ConnectivityManager.NetworkCallback() {
                @Override public void onAvailable(Network network) { ui.post(() -> networkChanged(true)); }
                @Override public void onLost(Network network) { ui.post(() -> networkChanged(false)); }
            };
            try { connectivity.registerDefaultNetworkCallback(networkCallback); }
            catch (RuntimeException ignored) { networkCallback = null; }
        }
        if (powerReceiver == null) {
            powerReceiver = new BroadcastReceiver() {
                @Override public void onReceive(Context context, Intent intent) { networkChanged(false); }
            };
            IntentFilter filter = new IntentFilter();
            filter.addAction(Intent.ACTION_POWER_CONNECTED);
            filter.addAction(Intent.ACTION_POWER_DISCONNECTED);
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(powerReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
            else registerReceiver(powerReceiver, filter);
        }
    }

    private void networkChanged(boolean refreshDiscovery) {
        if (!resumed) return;
        router.networkChanged();
        if (refreshDiscovery) startDiscovery();
        if (client == null && !sessions.hostAsleep() && SystemClock.elapsedRealtime() - lastConnectRequest > 1000) startSession();
    }

    private void stopNetworkMonitoring() {
        if (networkCallback != null && connectivity != null) {
            try { connectivity.unregisterNetworkCallback(networkCallback); } catch (RuntimeException ignored) { }
        }
        networkCallback = null;
        if (powerReceiver != null) {
            try { unregisterReceiver(powerReceiver); } catch (RuntimeException ignored) { }
        }
        powerReceiver = null;
    }

    private LinearLayout row() {
        LinearLayout row = new LinearLayout(this);
        row.setGravity(Gravity.CENTER_VERTICAL);
        return row;
    }

    private HorizontalScrollView scrolling(LinearLayout row) {
        HorizontalScrollView scroll = new HorizontalScrollView(this);
        scroll.addView(row);
        return scroll;
    }

    private Button button(String text, Runnable action) {
        Button button = new Button(this);
        button.setText(text);
        button.setAllCaps(false);
        button.setOnClickListener(view -> action.run());
        return button;
    }

    private EditText field(LinearLayout parent, String label, String value, boolean password) {
        TextView title = new TextView(this);
        title.setText(label);
        parent.addView(title);
        EditText edit = new EditText(this);
        edit.setSingleLine(true);
        edit.setInputType(InputType.TYPE_CLASS_TEXT | (password ? InputType.TYPE_TEXT_VARIATION_PASSWORD : InputType.TYPE_TEXT_VARIATION_URI));
        edit.setText(value);
        edit.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
        parent.addView(edit, new LinearLayout.LayoutParams(-1, -2));
        return edit;
    }

    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }

    private static final class PendingFrame {
        final int session;
        final Bitmap bitmap;
        final PinnedClient owner;
        final String captureSession;
        PendingFrame(int session, PinnedClient owner, String captureSession, Bitmap bitmap) {
            this.session = session; this.owner = owner; this.captureSession = captureSession; this.bitmap = bitmap;
        }
    }
}
