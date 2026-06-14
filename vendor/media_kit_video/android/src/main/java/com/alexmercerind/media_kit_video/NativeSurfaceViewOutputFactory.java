/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 *
 * Copyright 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import android.content.Context;

import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMessageCodec;
import io.flutter.plugin.platform.PlatformView;
import io.flutter.plugin.platform.PlatformViewFactory;

public class NativeSurfaceViewOutputFactory extends PlatformViewFactory {
    private final MethodChannel channel;
    private final NativeSurfaceViewOutputManager manager;

    NativeSurfaceViewOutputFactory(MethodChannel channel, NativeSurfaceViewOutputManager manager) {
        super(StandardMessageCodec.INSTANCE);
        this.channel = channel;
        this.manager = manager;
    }

    @Override
    public PlatformView create(Context context, int viewId, Object args) {
        return new NativeSurfaceViewOutput(context, channel, manager, args);
    }
}
