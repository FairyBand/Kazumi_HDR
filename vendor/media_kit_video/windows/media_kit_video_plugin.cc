// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.
#include "media_kit_video_plugin.h"
#include "utils.h"

#include <Windows.h>
#include <string>

namespace media_kit_video {

namespace {
constexpr const char* kNativeRtxHdrFilter =
    "d3d11vpp=format=x2bgr10:nvidia-true-hdr=yes";

std::string GetMpvPropertyString(mpv_handle* handle, const char* name) {
  char* value = mpv_get_property_string(handle, name);
  std::string result = value ? std::string(value) : "";
  if (value) {
    mpv_free(value);
  }
  return result;
}
}  // namespace

MediaKitVideoPlugin* MediaKitVideoPlugin::instance_ = nullptr;

void MediaKitVideoPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<MediaKitVideoPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

MediaKitVideoPlugin::MediaKitVideoPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      video_output_manager_(std::make_unique<VideoOutputManager>(
          registrar,
          [this](std::function<void()> task) {
            RunOnMainThread(std::move(task));
          })) {
  instance_ = this;
  flutter_view_window_ = registrar->GetView()->GetNativeWindow();
  flutter_window_ =
      ::GetAncestor(flutter_view_window_, GA_ROOT);
  original_window_proc_ = reinterpret_cast<WNDPROC>(
      ::SetWindowLongPtr(flutter_window_, GWLP_WNDPROC,
                         reinterpret_cast<LONG_PTR>(WindowProcDelegate)));

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "com.alexmercerind/media_kit_video",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([&](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

MediaKitVideoPlugin::~MediaKitVideoPlugin() {
  SetFlutterOverlayTransparency(false);
  video_output_manager_.reset();
  if (flutter_window_ && original_window_proc_) {
    ::SetWindowLongPtr(flutter_window_, GWLP_WNDPROC,
                       reinterpret_cast<LONG_PTR>(original_window_proc_));
  }
  if (instance_ == this) {
    instance_ = nullptr;
  }
}

void MediaKitVideoPlugin::RunOnMainThread(std::function<void()> task) {
  if (!flutter_window_) {
    task();
    return;
  }

  {
    std::lock_guard<std::mutex> lock(main_thread_tasks_mutex_);
    main_thread_tasks_.push(std::move(task));
  }

  ::PostMessage(flutter_window_, kMainThreadTaskMessage, 0, 0);
}

void MediaKitVideoPlugin::SetFlutterOverlayTransparency(bool enabled) {
  if (!flutter_window_) {
    return;
  }

  if (enabled) {
    SetWindowAccentTransparency(true);
    if (!native_window_sync_timer_running_) {
      ::SetTimer(flutter_window_, kNativeWindowSyncTimerId,
                 kNativeWindowSyncIntervalMs, nullptr);
      native_window_sync_timer_running_ = true;
    }
    flutter_overlay_transparent_ = true;
    ::RedrawWindow(flutter_window_, nullptr, nullptr,
                   RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_ALLCHILDREN);
    return;
  }

  if (!flutter_overlay_transparent_) {
    if (native_window_sync_timer_running_) {
      ::KillTimer(flutter_window_, kNativeWindowSyncTimerId);
      native_window_sync_timer_running_ = false;
    }
    return;
  }

  SetWindowAccentTransparency(false);
  if (native_window_sync_timer_running_) {
    ::KillTimer(flutter_window_, kNativeWindowSyncTimerId);
    native_window_sync_timer_running_ = false;
  }
  ::RedrawWindow(flutter_window_, nullptr, nullptr,
                 RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_ALLCHILDREN);
  flutter_overlay_transparent_ = false;
}

void MediaKitVideoPlugin::SetWindowAccentTransparency(bool enabled) {
  auto user32 = ::LoadLibraryW(L"user32.dll");
  if (!user32) {
    return;
  }

  typedef enum _ACCENT_STATE {
    ACCENT_DISABLED = 0,
    ACCENT_ENABLE_GRADIENT = 1,
    ACCENT_ENABLE_TRANSPARENTGRADIENT = 2,
    ACCENT_ENABLE_BLURBEHIND = 3,
    ACCENT_ENABLE_ACRYLICBLURBEHIND = 4,
    ACCENT_ENABLE_HOSTBACKDROP = 5,
    ACCENT_INVALID_STATE = 6
  } ACCENT_STATE;
  struct ACCENTPOLICY {
    int nAccentState;
    int nFlags;
    int nColor;
    int nAnimationId;
  };
  struct WINCOMPATTRDATA {
    int nAttribute;
    PVOID pData;
    ULONG ulDataSize;
  };
  typedef BOOL(WINAPI * pSetWindowCompositionAttribute)(HWND,
                                                        WINCOMPATTRDATA*);

  const pSetWindowCompositionAttribute SetWindowCompositionAttribute =
      reinterpret_cast<pSetWindowCompositionAttribute>(
          ::GetProcAddress(user32, "SetWindowCompositionAttribute"));
  if (SetWindowCompositionAttribute) {
    ACCENTPOLICY policy = {
        enabled ? ACCENT_ENABLE_TRANSPARENTGRADIENT : ACCENT_DISABLED,
        2,
        0,
        0};
    WINCOMPATTRDATA data = {19, &policy, sizeof(policy)};
    SetWindowCompositionAttribute(flutter_window_, &data);
  }

  ::FreeLibrary(user32);
}

LRESULT CALLBACK MediaKitVideoPlugin::WindowProcDelegate(HWND hwnd,
                                                         UINT message,
                                                         WPARAM wParam,
                                                         LPARAM lParam) {
  if (message == kMainThreadTaskMessage && instance_) {
    instance_->ProcessMainThreadTasks();
    return 0;
  }

  if (message == WM_TIMER && instance_ &&
      wParam == kNativeWindowSyncTimerId) {
    if (instance_->video_output_manager_) {
      instance_->video_output_manager_->SyncNativeWindowRects();
    }
    return 0;
  }

  if (instance_ && instance_->original_window_proc_) {
    auto result = ::CallWindowProc(instance_->original_window_proc_, hwnd,
                                   message, wParam, lParam);
    if (instance_->video_output_manager_ &&
        (message == WM_MOVE || message == WM_MOVING || message == WM_SIZE ||
         message == WM_WINDOWPOSCHANGED || message == WM_WINDOWPOSCHANGING ||
         message == WM_EXITSIZEMOVE || message == WM_STYLECHANGED ||
         message == WM_ACTIVATE)) {
      if (message == WM_MOVING && lParam) {
        auto proposed_rect = reinterpret_cast<RECT*>(lParam);
        POINT current_client_origin = {0, 0};
        RECT current_window_rect = {};
        ::ClientToScreen(hwnd, &current_client_origin);
        ::GetWindowRect(hwnd, &current_window_rect);
        instance_->video_output_manager_->SyncNativeWindowRectsWithClientOrigin(
            proposed_rect->left +
                (current_client_origin.x - current_window_rect.left),
            proposed_rect->top +
                (current_client_origin.y - current_window_rect.top));
      } else {
        instance_->video_output_manager_->SyncNativeWindowRects();
      }
    }
    return result;
  }

  return ::DefWindowProc(hwnd, message, wParam, lParam);
}

void MediaKitVideoPlugin::ProcessMainThreadTasks() {
  std::queue<std::function<void()>> tasks_to_execute;

  {
    std::lock_guard<std::mutex> lock(main_thread_tasks_mutex_);
    tasks_to_execute.swap(main_thread_tasks_);
  }

  while (!tasks_to_execute.empty()) {
    auto task = std::move(tasks_to_execute.front());
    tasks_to_execute.pop();

    try {
      task();
    } catch (...) {
    }
  }
}

void MediaKitVideoPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name().compare("VideoOutputManager.Create") == 0) {
    auto arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    auto handle =
        std::get<std::string>(arguments[flutter::EncodableValue("handle")]);
    auto configuration = std::get<flutter::EncodableMap>(
        arguments[flutter::EncodableValue("configuration")]);

    auto handle_value = std::stoll(handle);
    auto configuration_value = VideoOutputConfiguration{};

    auto configuration_width =
        std::get<std::string>(configuration[flutter::EncodableValue("width")]);
    auto configuration_height =
        std::get<std::string>(configuration[flutter::EncodableValue("height")]);
    auto configuration_enable_hardware_acceleration = std::get<bool>(
        configuration[flutter::EncodableValue("enableHardwareAcceleration")]);
    auto configuration_windows_native_window = std::get<bool>(
        configuration[flutter::EncodableValue("windowsNativeWindow")]);
    auto configuration_windows_native_rtx_hdr = std::get<bool>(
        configuration[flutter::EncodableValue("windowsNativeRtxHdr")]);
    if (configuration_width.compare("null") != 0) {
      configuration_value.width =
          static_cast<int64_t>(std::stoll(configuration_width.c_str()));
    }
    if (configuration_height.compare("null") != 0) {
      configuration_value.height =
          static_cast<int64_t>(std::stoll(configuration_height.c_str()));
    }
    configuration_value.enable_hardware_acceleration =
        configuration_enable_hardware_acceleration;
    configuration_value.windows_native_window =
        configuration_windows_native_window;
    configuration_value.windows_native_rtx_hdr =
        configuration_windows_native_rtx_hdr;

    video_output_manager_->Create(
        handle_value, configuration_value,
        [this, handle = handle_value](auto id, auto width, auto height) {
          RunOnMainThread([=]() {
            channel_->InvokeMethod(
                "VideoOutput.Resize",
                std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                    {
                        flutter::EncodableValue("handle"),
                        flutter::EncodableValue(handle),
                    },
                    {
                        flutter::EncodableValue("id"),
                        flutter::EncodableValue(id),
                    },
                    {
                        flutter::EncodableValue("rect"),
                        flutter::EncodableValue(flutter::EncodableMap{
                            {
                                flutter::EncodableValue("left"),
                                flutter::EncodableValue(0),
                            },
                            {
                                flutter::EncodableValue("top"),
                                flutter::EncodableValue(0),
                            },
                            {
                                flutter::EncodableValue("width"),
                                flutter::EncodableValue(width),
                            },
                            {
                                flutter::EncodableValue("height"),
                                flutter::EncodableValue(height),
                            },
                        }),
                    },
                }),
                nullptr);
          });
        });
    result->Success(flutter::EncodableValue(std::monostate{}));
  } else if (method_call.method_name().compare("VideoOutputManager.Dispose") ==
             0) {
    auto arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    auto handle =
        std::get<std::string>(arguments[flutter::EncodableValue("handle")]);
    auto handle_value = static_cast<int64_t>(std::stoll(handle.c_str()));
    video_output_manager_->Dispose(handle_value);
    result->Success(flutter::EncodableValue(std::monostate{}));
  } else if (method_call.method_name().compare("VideoOutputManager.SetSize") ==
             0) {
    auto arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    auto handle =
        std::get<std::string>(arguments[flutter::EncodableValue("handle")]);
    auto width =
        std::get<std::string>(arguments[flutter::EncodableValue("width")]);
    auto height =
        std::get<std::string>(arguments[flutter::EncodableValue("height")]);
    auto handle_value = static_cast<int64_t>(std::stoll(handle.c_str()));
    auto width_value = std::optional<int64_t>{};
    auto height_value = std::optional<int64_t>{};
    if (width.compare("null") != 0) {
      width_value = static_cast<int64_t>(std::stoll(width.c_str()));
    }
    if (height.compare("null") != 0) {
      height_value = static_cast<int64_t>(std::stoll(height.c_str()));
    }
    video_output_manager_->SetSize(handle_value, width_value, height_value);
    result->Success(flutter::EncodableValue(std::monostate{}));
  } else if (method_call.method_name().compare(
                 "VideoOutputManager.SetFlutterOverlayTransparency") == 0) {
    auto arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    auto enabled =
        std::get<bool>(arguments[flutter::EncodableValue("enabled")]);
    SetFlutterOverlayTransparency(enabled);
    result->Success(flutter::EncodableValue(std::monostate{}));
  } else if (method_call.method_name().compare(
                 "VideoOutputManager.SetNativeRect") == 0) {
    auto arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    auto handle =
        std::get<std::string>(arguments[flutter::EncodableValue("handle")]);
    auto left =
        std::get<std::string>(arguments[flutter::EncodableValue("left")]);
    auto top = std::get<std::string>(arguments[flutter::EncodableValue("top")]);
    auto width =
        std::get<std::string>(arguments[flutter::EncodableValue("width")]);
    auto height =
        std::get<std::string>(arguments[flutter::EncodableValue("height")]);
    auto clip_top = std::string("0");
    auto clip_bottom = std::string("0");
    if (auto value = arguments.find(flutter::EncodableValue("clipTop"));
        value != arguments.end()) {
      clip_top = std::get<std::string>(value->second);
    }
    if (auto value = arguments.find(flutter::EncodableValue("clipBottom"));
        value != arguments.end()) {
      clip_bottom = std::get<std::string>(value->second);
    }

    video_output_manager_->SetNativeWindowRect(
        static_cast<int64_t>(std::stoll(handle.c_str())),
        static_cast<int64_t>(std::stoll(left.c_str())),
        static_cast<int64_t>(std::stoll(top.c_str())),
        static_cast<int64_t>(std::stoll(width.c_str())),
        static_cast<int64_t>(std::stoll(height.c_str())),
        static_cast<int64_t>(std::stoll(clip_top.c_str())),
        static_cast<int64_t>(std::stoll(clip_bottom.c_str())));
    result->Success(flutter::EncodableValue(std::monostate{}));
  } else if (method_call.method_name().compare(
                 "VideoOutputManager.ApplyNativeRtxHdr") == 0) {
    auto arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    auto handle =
        std::get<std::string>(arguments[flutter::EncodableValue("handle")]);
    auto handle_value = static_cast<int64_t>(std::stoll(handle.c_str()));
    auto mpv_handle_value = reinterpret_cast<mpv_handle*>(handle_value);
    auto filter = std::string(kNativeRtxHdrFilter);
    if (auto value = arguments.find(flutter::EncodableValue("filter"));
        value != arguments.end()) {
      filter = std::get<std::string>(value->second);
    }
    const int property_result =
        mpv_set_property_string(mpv_handle_value, "vf", filter.c_str());
    const char* set_args[] = {"change-list", "vf", "set", filter.c_str(),
                              nullptr};
    const int command_result = mpv_command(mpv_handle_value, set_args);
    const int hint_result = mpv_set_property_string(
        mpv_handle_value, "target-colorspace-hint", "auto");
    const int strict_result = mpv_set_property_string(
        mpv_handle_value, "target-colorspace-hint-strict", "yes");
    const int format_result = mpv_set_property_string(
        mpv_handle_value, "d3d11-output-format", "auto");
    const int csp_result =
        mpv_set_property_string(mpv_handle_value, "d3d11-output-csp", "auto");
    const int trc_result =
        mpv_set_property_string(mpv_handle_value, "target-trc", "auto");
    const int prim_result =
        mpv_set_property_string(mpv_handle_value, "target-prim", "auto");
    const int hdr_peak_result =
        mpv_set_property_string(mpv_handle_value, "hdr-compute-peak", "no");
    const int inverse_result =
        mpv_set_property_string(mpv_handle_value, "inverse-tone-mapping", "no");
    auto response = flutter::EncodableMap{
        {flutter::EncodableValue("propertyResult"),
         flutter::EncodableValue(property_result)},
        {flutter::EncodableValue("propertyError"),
         flutter::EncodableValue(std::string(mpv_error_string(property_result)))},
        {flutter::EncodableValue("commandResult"),
         flutter::EncodableValue(command_result)},
        {flutter::EncodableValue("commandError"),
         flutter::EncodableValue(std::string(mpv_error_string(command_result)))},
        {flutter::EncodableValue("hintResult"),
         flutter::EncodableValue(hint_result)},
        {flutter::EncodableValue("strictResult"),
         flutter::EncodableValue(strict_result)},
        {flutter::EncodableValue("formatResult"),
         flutter::EncodableValue(format_result)},
        {flutter::EncodableValue("cspResult"), flutter::EncodableValue(csp_result)},
        {flutter::EncodableValue("trcResult"), flutter::EncodableValue(trc_result)},
        {flutter::EncodableValue("primResult"),
         flutter::EncodableValue(prim_result)},
        {flutter::EncodableValue("hdrPeakResult"),
         flutter::EncodableValue(hdr_peak_result)},
        {flutter::EncodableValue("inverseResult"),
         flutter::EncodableValue(inverse_result)},
        {flutter::EncodableValue("requestedFilter"),
         flutter::EncodableValue(filter)},
        {flutter::EncodableValue("vf"),
         flutter::EncodableValue(GetMpvPropertyString(mpv_handle_value, "vf"))},
        {flutter::EncodableValue("hwdecCurrent"),
         flutter::EncodableValue(
             GetMpvPropertyString(mpv_handle_value, "hwdec-current"))},
        {flutter::EncodableValue("videoOutFormat"),
         flutter::EncodableValue(GetMpvPropertyString(
             mpv_handle_value, "video-out-params/pixelformat"))},
        {flutter::EncodableValue("d3d11OutputFormat"),
         flutter::EncodableValue(GetMpvPropertyString(
             mpv_handle_value, "d3d11-output-format"))},
    };
    result->Success(flutter::EncodableValue(response));
  } else if (method_call.method_name().compare("Utils.EnterNativeFullscreen") ==
             0) {
    auto window =
        ::GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT);
    Utils::EnterNativeFullscreen(window);
    video_output_manager_->SyncNativeWindowRects();
    result->Success(flutter::EncodableValue(std::monostate{}));
  } else if (method_call.method_name().compare("Utils.ExitNativeFullscreen") ==
             0) {
    auto window =
        ::GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT);
    Utils::ExitNativeFullscreen(window);
    video_output_manager_->SyncNativeWindowRects();
    result->Success(flutter::EncodableValue(std::monostate{}));
  } else {
    result->NotImplemented();
  }
}

}  // namespace media_kit_video
