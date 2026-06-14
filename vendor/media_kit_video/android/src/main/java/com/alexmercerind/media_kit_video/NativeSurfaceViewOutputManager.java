/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 *
 * Copyright 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import java.util.HashMap;
import java.util.Objects;

public class NativeSurfaceViewOutputManager {
    private final HashMap<Long, NativeSurfaceViewOutput> outputs = new HashMap<>();
    private final Object lock = new Object();

    public void add(long handle, NativeSurfaceViewOutput output) {
        synchronized (lock) {
            outputs.put(handle, output);
        }
    }

    public void remove(long handle, NativeSurfaceViewOutput output) {
        synchronized (lock) {
            if (Objects.equals(outputs.get(handle), output)) {
                outputs.remove(handle);
            }
        }
    }

    public void setSurfaceSize(long handle, int width, int height) {
        synchronized (lock) {
            final NativeSurfaceViewOutput output = outputs.get(handle);
            if (output != null) {
                output.setSize(width, height);
            }
        }
    }

    public void dispose(long handle) {
        synchronized (lock) {
            final NativeSurfaceViewOutput output = outputs.remove(handle);
            if (output != null) {
                output.disposeInternal();
            }
        }
    }
}
