package local.boox.sidecar;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.util.Log;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.os.SystemClock;

/** One displayed bitmap, aspect-preserving coordinates, no history or animation queue. */
final class FrameView extends View {
    interface InputListener {
        void tap(String captureSession, double x, double y, int clickCount);
        void rightClick(String captureSession, double x, double y);
        void scroll(String captureSession, double x, double y, double delta);
        void drag(String captureSession, String phase, String dragId, double x, double y);
    }
    private final Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
    private final RectF imageBounds = new RectF();
    private Bitmap bitmap;
    private int currentSession = -1;
    private int lastDrawnSession = -1;
    private String frameCaptureSession = "";
    private String drawnCaptureSession = "";
    private final TouchGesture gesture;
    private boolean inputEnabled;
    private InputListener listener;
    private final Runnable longPress = this::checkLongPress;
    private final Runnable dragHeartbeat = this::keepDragAlive;

    FrameView(Context context) {
        super(context);
        ViewConfiguration configuration = ViewConfiguration.get(context);
        gesture = new TouchGesture(configuration.getScaledTouchSlop(), configuration.getScaledDoubleTapSlop(),
                ViewConfiguration.getDoubleTapTimeout(), ViewConfiguration.getLongPressTimeout(), new TouchGesture.Listener() {
            @Override public void tap(String capture, double x, double y, int count) {
                if (inputEnabled && listener != null) listener.tap(capture, x, y, count);
            }
            @Override public void scroll(String capture, double x, double y, double delta) {
                if (inputEnabled && listener != null) listener.scroll(capture, x, y, delta);
            }
            @Override public void rightClick(String capture, double x, double y) {
                if (inputEnabled && listener != null) listener.rightClick(capture, x, y);
            }
            @Override public void drag(String capture, String phase, String dragId, double x, double y) {
                if (inputEnabled && listener != null) listener.drag(capture, phase, dragId, x, y);
            }
        });
        setBackgroundColor(Color.WHITE);
        setContentDescription("Mac display. Enable input on the Mac to tap, drag with one finger, scroll with two fingers, or hold for right-click.");
    }

    void setFrame(Bitmap frame, int session, String captureSession) {
        if (bitmap != null && (bitmap.getWidth() != frame.getWidth() || bitmap.getHeight() != frame.getHeight())) { cancelTimers(); gesture.clear(); }
        bitmap = frame;
        currentSession = session;
        frameCaptureSession = captureSession;
        invalidate();
    }

    void clearFrame() {
        bitmap = null;
        frameCaptureSession = "";
        drawnCaptureSession = "";
        gesture.clear();
        cancelTimers();
        imageBounds.setEmpty();
        invalidate();
    }
    void setInput(boolean enabled, InputListener listener) {
        inputEnabled = enabled;
        this.listener = listener;
        if (!enabled) { cancelTimers(); gesture.cancel(); }
    }

    @Override protected void onSizeChanged(int width, int height, int oldWidth, int oldHeight) {
        super.onSizeChanged(width, height, oldWidth, oldHeight);
        gesture.clear();
        cancelTimers();
        drawnCaptureSession = "";
    }

    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        if (bitmap == null) { imageBounds.setEmpty(); return; }
        float scale = Math.min((float) getWidth() / bitmap.getWidth(), (float) getHeight() / bitmap.getHeight());
        float width = bitmap.getWidth() * scale;
        float height = bitmap.getHeight() * scale;
        imageBounds.set((getWidth() - width) / 2, (getHeight() - height) / 2,
                (getWidth() + width) / 2, (getHeight() + height) / 2);
        canvas.drawBitmap(bitmap, null, imageBounds, paint);
        drawnCaptureSession = frameCaptureSession;
        gesture.frame(drawnCaptureSession, imageBounds.left, imageBounds.top, imageBounds.width(), imageBounds.height());
        if (lastDrawnSession != currentSession) {
            lastDrawnSession = currentSession;
            Log.i("BooxSidecar", "First native frame drawn: " + bitmap.getWidth() + "x" + bitmap.getHeight()
                    + " session=" + currentSession);
        }
    }

    @Override public boolean onTouchEvent(MotionEvent event) {
        if (!inputEnabled || listener == null || drawnCaptureSession.isEmpty()) return false;
        if (event.getPointerCount() > 2) { cancelTimers(); gesture.cancel(); return true; }
        if (event.getActionMasked() == MotionEvent.ACTION_POINTER_DOWN) {
            cancelTimers();
            if (event.getPointerCount() == 2 && imageBounds.contains(event.getX(0), event.getY(0))
                    && imageBounds.contains(event.getX(1), event.getY(1))) {
                gesture.startScroll((event.getX(0) + event.getX(1)) / 2, (event.getY(0) + event.getY(1)) / 2);
            } else gesture.cancel();
            return true;
        }
        if (event.getActionMasked() == MotionEvent.ACTION_POINTER_UP) {
            cancelTimers();
            if (event.getPointerCount() == 2) gesture.up((event.getX(0) + event.getX(1)) / 2,
                    (event.getY(0) + event.getY(1)) / 2, event.getEventTime());
            else gesture.cancel();
            return true;
        }
        if (event.getActionMasked() == MotionEvent.ACTION_DOWN) {
            cancelTimers();
            boolean accepted = gesture.down(event.getX(), event.getY(), event.getEventTime());
            if (accepted) postDelayed(longPress, ViewConfiguration.getLongPressTimeout());
            return accepted;
        }
        if (event.getActionMasked() == MotionEvent.ACTION_CANCEL) {
            gesture.cancel();
            cancelTimers();
            return true;
        }
        if (event.getActionMasked() == MotionEvent.ACTION_MOVE) {
            if (event.getPointerCount() == 2) gesture.move((event.getX(0) + event.getX(1)) / 2, (event.getY(0) + event.getY(1)) / 2);
            else gesture.move(event.getX(), event.getY());
            removeCallbacks(dragHeartbeat);
            if (gesture.dragging()) { removeCallbacks(longPress); postDelayed(dragHeartbeat, 500); }
        }
        if (event.getActionMasked() == MotionEvent.ACTION_UP) {
            cancelTimers();
            if (gesture.up(event.getX(), event.getY(), event.getEventTime())) performClick();
            return true;
        }
        return true;
    }

    @Override public boolean performClick() { super.performClick(); return true; }

    private void checkLongPress() {
        if (inputEnabled) gesture.longPress(SystemClock.uptimeMillis());
    }

    private void keepDragAlive() {
        if (inputEnabled && gesture.dragging()) {
            gesture.heartbeat();
            postDelayed(dragHeartbeat, 500);
        }
    }

    private void cancelTimers() {
        removeCallbacks(longPress);
        removeCallbacks(dragHeartbeat);
    }

    @Override protected void onDetachedFromWindow() {
        cancelTimers();
        gesture.cancel();
        super.onDetachedFromWindow();
    }
}
