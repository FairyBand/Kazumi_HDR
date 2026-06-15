#include "flutter_window.h"
#include "fullscreen_utils.h"
#include "external_player_utils.h"
#include "shortcut_utils.h"

#include <optional>
#include <dwmapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/plugin_registrar_windows.h>
#include <windows.h>

#include "flutter/generated_plugin_registrant.h"

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR 34
#endif

#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35
#endif

#ifndef DWMWA_TEXT_COLOR
#define DWMWA_TEXT_COLOR 36
#endif

namespace {

HRESULT ApplyTitleBarAppearance(HWND window, bool dark) {
  BOOL enable_dark_mode = dark;
  HRESULT dark_mode_result =
      DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                            &enable_dark_mode, sizeof(enable_dark_mode));

  COLORREF caption_color =
      dark ? RGB(32, 32, 32) : RGB(255, 255, 255);
  COLORREF text_color = dark ? RGB(255, 255, 255) : RGB(0, 0, 0);
  COLORREF border_color =
      dark ? RGB(48, 48, 48) : RGB(217, 217, 217);

  DwmSetWindowAttribute(window, DWMWA_CAPTION_COLOR, &caption_color,
                        sizeof(caption_color));
  DwmSetWindowAttribute(window, DWMWA_TEXT_COLOR, &text_color,
                        sizeof(text_color));
  DwmSetWindowAttribute(window, DWMWA_BORDER_COLOR, &border_color,
                        sizeof(border_color));

  return dark_mode_result;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Removed automatic window show to let window_manager plugin control visibility
  // This prevents window flashing during startup
  // flutter_controller_->engine()->SetNextFrameCallback([&]() {
  //   this->Show();
  // });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // Register Intent MethodChannel
  RegisterIntentChannel();

  // Register Storage MethodChannel
  RegisterStorageChannel();

  // Register Shortcut MethodChannel
  RegisterShortcutChannel();

  // Register Windows title bar MethodChannel
  RegisterWindowsTitleBarChannel();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

// Intent MethodChannel setup
void FlutterWindow::RegisterIntentChannel() {
  auto window_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "com.predidit.kazumi/intent",
          &flutter::StandardMethodCodec::GetInstance());

  window_channel->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name().compare("enterFullscreen") == 0) {
      FullscreenUtils::EnterNativeFullscreen(GetHandle());
      result->Success();
    } else if (call.method_name().compare("exitFullscreen") == 0) {
      FullscreenUtils::ExitNativeFullscreen(GetHandle());
      result->Success();
    } else if (call.method_name().compare("openWithMime") == 0) {
      const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
      if (arguments) {
        auto url_it = arguments->find(flutter::EncodableValue("url"));
        if (url_it != arguments->end()) {
          const std::string& url = std::get<std::string>(url_it->second);
          ExternalPlayerUtils::OpenWithPlayer(url.c_str());
          result->Success();
        } else {
          result->Error("InvalidArguments", "Missing 'url' argument");
        }
      } else {
        result->Error("InvalidArguments", "Arguments are not a map");
      }
    } else {
      result->NotImplemented();
    }
  });
}

// Storage MethodChannel setup
void FlutterWindow::RegisterStorageChannel() {
  auto storage_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "com.predidit.kazumi/storage",
          &flutter::StandardMethodCodec::GetInstance());

  storage_channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name().compare("getAvailableStorage") == 0) {
      std::wstring path = L"C:\\";
      const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
      if (arguments) {
        auto path_it = arguments->find(flutter::EncodableValue("path"));
        if (path_it != arguments->end()) {
          const std::string& path_str = std::get<std::string>(path_it->second);
          // Extract drive root from path (e.g. "C:\Users\..." -> "C:\")
          if (path_str.length() >= 2 && path_str[1] == ':') {
            path = std::wstring(1, static_cast<wchar_t>(path_str[0])) + L":\\";
          }
        }
      }

      ULARGE_INTEGER free_bytes_available;
      if (GetDiskFreeSpaceExW(path.c_str(), &free_bytes_available, nullptr, nullptr)) {
        result->Success(flutter::EncodableValue(static_cast<int64_t>(free_bytes_available.QuadPart)));
      } else {
        result->Success(flutter::EncodableValue(static_cast<int64_t>(-1)));
      }
    } else {
      result->NotImplemented();
    }
  });
}

// Shortcut MethodChannel setup
void FlutterWindow::RegisterShortcutChannel() {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "com.predidit.kazumi/shortcut",
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "createDesktopShortcut") {
      result->NotImplemented();
      return;
    }

    bool success = ShortcutUtils::CreateDesktopShortcut(L"Kazumi", L"Kazumi - Anime Player");
    if (success) {
      result->Success(flutter::EncodableValue(true));
    } else {
      result->Error("Failed", "Failed to create desktop shortcut");
    }
  });
}

void FlutterWindow::RegisterWindowsTitleBarChannel() {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.predidit.kazumi/windows_title_bar",
          &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name().compare("setBrightness") == 0) {
      const auto* arguments =
          std::get_if<flutter::EncodableMap>(call.arguments());
      if (!arguments) {
        result->Error("InvalidArguments", "Arguments are not a map");
        return;
      }

      auto brightness_it =
          arguments->find(flutter::EncodableValue("brightness"));
      if (brightness_it == arguments->end()) {
        result->Error("InvalidArguments", "Missing 'brightness' argument");
        return;
      }

      const std::string& brightness =
          std::get<std::string>(brightness_it->second);
      HRESULT hr = ApplyTitleBarAppearance(GetHandle(), brightness == "dark");

      if (SUCCEEDED(hr)) {
        result->Success();
      } else {
        result->Error("DwmSetWindowAttributeFailed",
                      "Failed to update title bar brightness");
      }
      return;
    }

    result->NotImplemented();
    return;
  });
}
