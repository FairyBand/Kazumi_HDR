// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "fullscreen_utils.h"
#include "lifecycle_log.h"

void FullscreenUtils::EnterNativeFullscreen(HWND window) {
  if (fullscreen_ || !::IsWindow(window)) {
    return;
  }

  WINDOWPLACEMENT placement = {};
  placement.length = sizeof(WINDOWPLACEMENT);
  MONITORINFO monitor = {};
  monitor.cbSize = sizeof(MONITORINFO);
  if (!::GetWindowPlacement(window, &placement) ||
      !::GetMonitorInfo(
          ::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor)) {
    kazumi::LifecycleLog("fullscreen", "enter.capture_failed");
    return;
  }

  placement_before_fullscreen_ = placement;
  style_before_fullscreen_ = ::GetWindowLongPtr(window, GWL_STYLE);
  fullscreen_ = true;

  // Clear the complete overlapped-window frame, including WS_CAPTION. The
  // window_manager implementation only clears the resize/maximize bits when
  // the source window is maximized, leaving DWM's non-client frame visible.
  ::SetWindowLongPtr(window, GWL_STYLE,
                     style_before_fullscreen_ &
                         ~static_cast<LONG_PTR>(WS_OVERLAPPEDWINDOW));
  ::SetWindowPos(window, HWND_TOP, monitor.rcMonitor.left,
                 monitor.rcMonitor.top,
                 monitor.rcMonitor.right - monitor.rcMonitor.left,
                 monitor.rcMonitor.bottom - monitor.rcMonitor.top,
                 SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  kazumi::LifecycleLog(
      "fullscreen",
      std::string("enter.complete was_maximized=") +
          (placement.showCmd == SW_SHOWMAXIMIZED ? "1" : "0"));
}

void FullscreenUtils::ExitNativeFullscreen(HWND window) {
  if (!fullscreen_ || !::IsWindow(window)) {
    return;
  }

  // Hand non-client calculations back to window_manager before restoring the
  // original style and placement.
  fullscreen_ = false;
  ::SetWindowLongPtr(window, GWL_STYLE, style_before_fullscreen_);
  ::SetWindowPlacement(window, &placement_before_fullscreen_);
  ::SetWindowPos(window, nullptr, 0, 0, 0, 0,
                 SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                     SWP_NOOWNERZORDER | SWP_FRAMECHANGED);

  // Force the Flutter child to consume the restored client bounds now. This
  // avoids a stale one-frame surface after leaving fullscreen on a maximized
  // window.
  RECT rect = {};
  ::GetClientRect(window, &rect);
  auto flutter_view =
      ::FindWindowEx(window, nullptr, kFlutterViewWindowClassName, nullptr);
  if (flutter_view) {
    ::SetWindowPos(flutter_view, nullptr, rect.left, rect.top,
                   rect.right - rect.left, rect.bottom - rect.top,
                   SWP_NOACTIVATE | SWP_NOZORDER);
  }
  kazumi::LifecycleLog("fullscreen", "exit.complete");
}

bool FullscreenUtils::IsFullscreen() {
  return fullscreen_;
}

bool FullscreenUtils::fullscreen_ = false;

LONG_PTR FullscreenUtils::style_before_fullscreen_ = 0;

WINDOWPLACEMENT FullscreenUtils::placement_before_fullscreen_ =
    WINDOWPLACEMENT{};
