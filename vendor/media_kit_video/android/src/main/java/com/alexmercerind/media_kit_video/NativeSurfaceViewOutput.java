/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 *
 * Copyright 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import android.content.Context;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Gravity;
import android.view.Surface;
import android.view.SurfaceControl;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;

import java.lang.reflect.Method;
import java.util.HashSet;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;

import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.platform.PlatformView;

public class NativeSurfaceViewOutput implements PlatformView, SurfaceHolder.Callback {
    private static final String TAG = "NativeSurfaceViewOutput";
    private static final Method newGlobalObjectRef;
    private static final Method deleteGlobalObjectRef;
    private static final HashSet<Long> deletedGlobalObjectRefs = new HashSet<>();
    private static final Handler handler = new Handler(Looper.getMainLooper());

    static {
        try {
            Class<?> mediaKitAndroidHelperClass = Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper");
            newGlobalObjectRef = mediaKitAndroidHelperClass.getDeclaredMethod("newGlobalObjectRef", Object.class);
            deleteGlobalObjectRef = mediaKitAndroidHelperClass.getDeclaredMethod("deleteGlobalObjectRef", long.class);
            newGlobalObjectRef.setAccessible(true);
            deleteGlobalObjectRef.setAccessible(true);
        } catch (Throwable e) {
            Log.i("media_kit", "package:media_kit_libs_android_video missing. Make sure you have added it to pubspec.yaml.");
            throw new RuntimeException("Failed to initialize com.alexmercerind.media_kit_video.NativeSurfaceViewOutput.");
        }
    }

    private final MethodChannel channel;
    private final NativeSurfaceViewOutputManager manager;
    private final FrameLayout rootView;
    private final SurfaceView surfaceView;
    private final long handle;
    private final String fit;
    private final Object lock = new Object();

    private long wid = 0;
    private int width = 1;
    private int height = 1;
    private boolean disposed = false;
    private int lastLayoutRootWidth = 0;
    private int lastLayoutRootHeight = 0;
    private int lastLayoutChildWidth = 0;
    private int lastLayoutChildHeight = 0;

    @SuppressWarnings("unchecked")
    NativeSurfaceViewOutput(
        Context context,
        MethodChannel channel,
        NativeSurfaceViewOutputManager manager,
        Object args
    ) {
        this.channel = channel;
        this.manager = manager;
        final Map<String, Object> params = (Map<String, Object>) args;
        this.handle = Long.parseLong(String.valueOf(Objects.requireNonNull(params.get("handle"))));
        this.width = parsePositiveInt(params.get("width"), 1);
        this.height = parsePositiveInt(params.get("height"), 1);
        this.fit = String.valueOf(params.get("fit"));
        Log.i(TAG, String.format(
            Locale.ENGLISH,
            "create: handle=%d initialSize=%dx%d fit=%s",
            handle,
            width,
            height,
            fit
        ));

        rootView = new FrameLayout(context);
        rootView.setBackgroundColor(Color.TRANSPARENT);
        rootView.setClickable(false);
        rootView.setFocusable(false);
        surfaceView = new SurfaceView(context);
        surfaceView.setBackgroundColor(Color.TRANSPARENT);
        surfaceView.setClickable(false);
        surfaceView.setFocusable(false);
        surfaceView.setZOrderMediaOverlay(true);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            surfaceView.setDefaultFocusHighlightEnabled(false);
        }
        final SurfaceHolder holder = surfaceView.getHolder();
        holder.setFormat(PixelFormat.RGBA_1010102);
        holder.setSizeFromLayout();
        holder.setFixedSize(width, height);
        holder.addCallback(this);
        rootView.addView(
            surfaceView,
            new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
                Gravity.CENTER
            )
        );
        rootView.addOnLayoutChangeListener(
            (v, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom) -> applySurfaceLayout()
        );
        applySurfaceLayout();
        applyHdrSurfaceHints("create");
        manager.add(handle, this);
    }

    @Override
    public View getView() {
        return rootView;
    }

    @Override
    public void dispose() {
        manager.remove(handle, this);
        disposeInternal();
    }

    void disposeInternal() {
        synchronized (lock) {
            if (disposed) {
                return;
            }
            disposed = true;
            try {
                surfaceView.getHolder().removeCallback(this);
            } catch (Throwable e) {
                Log.e(TAG, "dispose removeCallback", e);
            }
            notifySurface(0, width, height);
            clearWid();
        }
    }

    public void setSize(int width, int height) {
        synchronized (lock) {
            this.width = Math.max(1, width);
            this.height = Math.max(1, height);
            Log.i(TAG, String.format(
                Locale.ENGLISH,
                "setSize: handle=%d size=%dx%d currentWid=%d",
                handle,
                this.width,
                this.height,
                wid
            ));
            try {
                surfaceView.getHolder().setFixedSize(this.width, this.height);
            } catch (Throwable e) {
                Log.e(TAG, "setSize", e);
            }
            applySurfaceLayout();
            applyHdrSurfaceHints("setSize");
            notifySurface(wid, this.width, this.height);
        }
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        synchronized (lock) {
            if (disposed) {
                return;
            }
            Log.i(TAG, String.format(
                Locale.ENGLISH,
                "surfaceCreated: handle=%d surface=%s valid=%s",
                handle,
                holder.getSurface(),
                holder.getSurface() != null && holder.getSurface().isValid()
            ));
            applyHdrSurfaceHints("surfaceCreated");
            replaceSurface(holder.getSurface());
        }
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        synchronized (lock) {
            if (disposed) {
                return;
            }
            Log.i(TAG, String.format(
                Locale.ENGLISH,
                "surfaceChanged: handle=%d format=%d holderSize=%dx%d requestedSize=%dx%d wid=%d",
                handle,
                format,
                width,
                height,
                this.width,
                this.height,
                wid
            ));
            if (wid == 0) {
                replaceSurface(holder.getSurface());
            } else {
                applyHdrSurfaceHints("surfaceChanged");
                notifySurface(wid, this.width, this.height);
            }
        }
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        synchronized (lock) {
            Log.i(TAG, String.format(Locale.ENGLISH, "surfaceDestroyed: handle=%d wid=%d", handle, wid));
            notifySurface(0, width, height);
            clearWid();
        }
    }

    private void replaceSurface(Surface surface) {
        clearWid();
        if (surface == null || !surface.isValid()) {
            Log.i(TAG, String.format(Locale.ENGLISH, "replaceSurface: handle=%d invalid surface", handle));
            notifySurface(0, width, height);
            return;
        }
        wid = newGlobalObjectRef(surface);
        Log.i(TAG, String.format(Locale.ENGLISH, "replaceSurface: handle=%d wid=%d", handle, wid));
        applyHdrSurfaceHints("replaceSurface");
        notifySurface(wid, width, height);
    }

    private void applyHdrSurfaceHints(String reason) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return;
        }
        try {
            final SurfaceControl surfaceControl = surfaceView.getSurfaceControl();
            if (surfaceControl == null || !surfaceControl.isValid()) {
                Log.i(TAG, String.format(
                    Locale.ENGLISH,
                    "hdrSurfaceHints skipped: handle=%d reason=%s surfaceControlValid=false",
                    handle,
                    reason
                ));
                return;
            }
            final SurfaceControl.Transaction transaction = new SurfaceControl.Transaction();
            try {
                transaction.setOpaque(surfaceControl, true);
                transaction.apply();
            } finally {
                transaction.close();
            }
            Log.i(TAG, String.format(
                Locale.ENGLISH,
                "hdrSurfaceHints applied: handle=%d reason=%s mediaOverlay=true format=RGBA_1010102",
                handle,
                reason
            ));
        } catch (Throwable e) {
            Log.w(TAG, String.format(Locale.ENGLISH, "hdrSurfaceHints failed: handle=%d reason=%s", handle, reason), e);
        }
    }

    private void applySurfaceLayout() {
        final int rootWidth = rootView.getWidth();
        final int rootHeight = rootView.getHeight();
        if (rootWidth <= 0 || rootHeight <= 0 || width <= 0 || height <= 0) {
            return;
        }

        int childWidth = rootWidth;
        int childHeight = rootHeight;
        if ("contain".equals(fit) || "cover".equals(fit)) {
            final float scaleX = (float) rootWidth / (float) width;
            final float scaleY = (float) rootHeight / (float) height;
            final float scale = "cover".equals(fit)
                ? Math.max(scaleX, scaleY)
                : Math.min(scaleX, scaleY);
            childWidth = Math.max(1, Math.round(width * scale));
            childHeight = Math.max(1, Math.round(height * scale));
        }

        final FrameLayout.LayoutParams params =
            (FrameLayout.LayoutParams) surfaceView.getLayoutParams();
        if (params.width == childWidth && params.height == childHeight) {
            return;
        }
        if (
            lastLayoutRootWidth != rootWidth ||
            lastLayoutRootHeight != rootHeight ||
            lastLayoutChildWidth != childWidth ||
            lastLayoutChildHeight != childHeight
        ) {
            lastLayoutRootWidth = rootWidth;
            lastLayoutRootHeight = rootHeight;
            lastLayoutChildWidth = childWidth;
            lastLayoutChildHeight = childHeight;
            Log.i(TAG, String.format(
                Locale.ENGLISH,
                "layout: handle=%d root=%dx%d child=%dx%d video=%dx%d fit=%s",
                handle,
                rootWidth,
                rootHeight,
                childWidth,
                childHeight,
                width,
                height,
                fit
            ));
        }
        params.width = childWidth;
        params.height = childHeight;
        params.gravity = Gravity.CENTER;
        surfaceView.setLayoutParams(params);
    }

    private void notifySurface(long wid, int width, int height) {
        Log.i(TAG, String.format(
            Locale.ENGLISH,
            "notifySurface: handle=%d wid=%d size=%dx%d",
            handle,
            wid,
            width,
            height
        ));
        channel.invokeMethod(
            "VideoOutput.NativeSurfaceView",
            new java.util.HashMap<String, Object>() {{
                put("handle", handle);
                put("wid", wid);
                put("width", width);
                put("height", height);
            }}
        );
    }

    private void clearWid() {
        if (wid == 0) {
            return;
        }
        final long widReference = wid;
        wid = 0;
        handler.postDelayed(() -> deleteGlobalObjectRef(widReference), 5000);
    }

    private static long newGlobalObjectRef(Object object) {
        Log.i(TAG, String.format(Locale.ENGLISH, "newGlobalRef: object = %s", object));
        try {
            return (long) Objects.requireNonNull(newGlobalObjectRef.invoke(null, object));
        } catch (Throwable e) {
            Log.e(TAG, "newGlobalRef", e);
            return 0;
        }
    }

    private static void deleteGlobalObjectRef(long ref) {
        if (deletedGlobalObjectRefs.contains(ref)) {
            Log.i(TAG, String.format(Locale.ENGLISH, "deleteGlobalObjectRef: ref = %d ALREADY DELETED", ref));
            return;
        }
        if (deletedGlobalObjectRefs.size() > 100) {
            deletedGlobalObjectRefs.clear();
        }
        deletedGlobalObjectRefs.add(ref);
        Log.i(TAG, String.format(Locale.ENGLISH, "deleteGlobalObjectRef: ref = %d", ref));
        try {
            deleteGlobalObjectRef.invoke(null, ref);
        } catch (Throwable e) {
            Log.e(TAG, "deleteGlobalObjectRef", e);
        }
    }

    private static int parsePositiveInt(Object value, int fallback) {
        if (value == null) {
            return fallback;
        }
        try {
            return Math.max(1, Integer.parseInt(String.valueOf(value)));
        } catch (Throwable e) {
            return fallback;
        }
    }
}
