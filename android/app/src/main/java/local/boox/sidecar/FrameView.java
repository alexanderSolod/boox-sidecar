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

/** One displayed bitmap, aspect-preserving coordinates, no history or animation queue. */
final class FrameView extends View {
    interface InputListener { void tap(String captureSession, double x, double y, int clickCount); void scroll(String captureSession, double delta); }
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

    FrameView(Context context) {
        super(context);
        ViewConfiguration configuration = ViewConfiguration.get(context);
        gesture = new TouchGesture(configuration.getScaledTouchSlop(), configuration.getScaledDoubleTapSlop(),
                ViewConfiguration.getDoubleTapTimeout(), ViewConfiguration.getLongPressTimeout(), new TouchGesture.Listener() {
            @Override public void tap(String capture, double x, double y, int count) {
                if (inputEnabled && listener != null) listener.tap(capture, x, y, count);
            }
            @Override public void scroll(String capture, double delta) {
                if (inputEnabled && listener != null) listener.scroll(capture, delta);
            }
        });
        setBackgroundColor(Color.WHITE);
        setContentDescription("Mac display. Enable remote input in controls to tap or scroll.");
    }

    void setFrame(Bitmap frame, int session, String captureSession) {
        if (bitmap != null && (bitmap.getWidth() != frame.getWidth() || bitmap.getHeight() != frame.getHeight())) gesture.clear();
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
        imageBounds.setEmpty();
        invalidate();
    }
    void setInput(boolean enabled, InputListener listener) {
        inputEnabled = enabled;
        this.listener = listener;
        if (!enabled) gesture.cancel();
    }

    @Override protected void onSizeChanged(int width, int height, int oldWidth, int oldHeight) {
        super.onSizeChanged(width, height, oldWidth, oldHeight);
        gesture.clear();
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
        if (event.getPointerCount() != 1) { gesture.cancel(); return true; }
        if (event.getActionMasked() == MotionEvent.ACTION_DOWN) {
            return gesture.down(event.getX(), event.getY(), event.getEventTime());
        }
        if (event.getActionMasked() == MotionEvent.ACTION_CANCEL) {
            gesture.cancel();
            return true;
        }
        if (event.getActionMasked() == MotionEvent.ACTION_MOVE) gesture.move(event.getX(), event.getY());
        if (event.getActionMasked() == MotionEvent.ACTION_UP) {
            if (gesture.up(event.getX(), event.getY(), event.getEventTime())) performClick();
            return true;
        }
        return true;
    }

    @Override public boolean performClick() { super.performClick(); return true; }
}
