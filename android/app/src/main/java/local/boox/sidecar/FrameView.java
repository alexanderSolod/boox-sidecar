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

/** One displayed bitmap, aspect-preserving coordinates, no history or animation queue. */
final class FrameView extends View {
    interface InputListener { void tap(double x, double y); void scroll(double delta); }
    private final Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
    private final RectF imageBounds = new RectF();
    private Bitmap bitmap;
    private int currentSession = -1;
    private int lastDrawnSession = -1;
    private float startX, startY;
    private boolean inputEnabled;
    private InputListener listener;

    FrameView(Context context) {
        super(context);
        setBackgroundColor(Color.WHITE);
        setContentDescription("Mac display. Enable remote input in controls to tap or scroll.");
    }

    void setFrame(Bitmap frame, int session) {
        bitmap = frame;
        currentSession = session;
        invalidate();
    }

    void clearFrame() { bitmap = null; imageBounds.setEmpty(); invalidate(); }
    void setInput(boolean enabled, InputListener listener) { inputEnabled = enabled; this.listener = listener; }

    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        if (bitmap == null) { imageBounds.setEmpty(); return; }
        float scale = Math.min((float) getWidth() / bitmap.getWidth(), (float) getHeight() / bitmap.getHeight());
        float width = bitmap.getWidth() * scale;
        float height = bitmap.getHeight() * scale;
        imageBounds.set((getWidth() - width) / 2, (getHeight() - height) / 2,
                (getWidth() + width) / 2, (getHeight() + height) / 2);
        canvas.drawBitmap(bitmap, null, imageBounds, paint);
        if (lastDrawnSession != currentSession) {
            lastDrawnSession = currentSession;
            Log.i("BooxSidecar", "First native frame drawn: " + bitmap.getWidth() + "x" + bitmap.getHeight()
                    + " session=" + currentSession);
        }
    }

    @Override public boolean onTouchEvent(MotionEvent event) {
        if (!inputEnabled || listener == null) return false;
        if (event.getActionMasked() == MotionEvent.ACTION_DOWN) {
            if (!imageBounds.contains(event.getX(), event.getY())) return false;
            startX = event.getX(); startY = event.getY();
            return true;
        }
        if (event.getActionMasked() == MotionEvent.ACTION_UP) {
            float dx = event.getX() - startX, dy = event.getY() - startY;
            float threshold = 12 * getResources().getDisplayMetrics().density;
            if (Math.abs(dy) > threshold) listener.scroll(Math.max(-1000, Math.min(1000, dy)));
            else if (Math.abs(dx) <= threshold && imageBounds.contains(event.getX(), event.getY())) {
                listener.tap((event.getX() - imageBounds.left) / imageBounds.width(),
                        (event.getY() - imageBounds.top) / imageBounds.height());
                performClick();
            }
            return true;
        }
        return true;
    }

    @Override public boolean performClick() { super.performClick(); return true; }
}
