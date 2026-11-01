#include "flutter_window.h"

#include <dwmapi.h>

#include <algorithm>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

// DWM attributes used to theme the native title bar. They are passed as raw
// DWORD values so the build does not depend on newer SDK enum names.
constexpr DWORD kDwmwaUseImmersiveDarkMode = 20;
constexpr DWORD kDwmwaBorderColor = 34;
constexpr DWORD kDwmwaCaptionColor = 35;
constexpr DWORD kDwmwaTextColor = 36;
constexpr DWORD kDwmwaSystemBackdropType = 38;
constexpr DWORD kDwmSbtNone = 1;
// Undocumented but widely used attribute that disables the Mica effect on
// Windows 11 builds that predate DWMWA_SYSTEMBACKDROP_TYPE.
constexpr DWORD kDwmwaMicaEffect = 1029;

flutter::EncodableValue Key(const char* key) {
  return flutter::EncodableValue(std::string(key));
}

bool ReadBool(const flutter::EncodableMap& arguments, const char* key,
              bool fallback) {
  const auto it = arguments.find(Key(key));
  if (it == arguments.end()) return fallback;
  if (const bool* value = std::get_if<bool>(&it->second)) return *value;
  if (const int32_t* value = std::get_if<int32_t>(&it->second)) {
    return *value != 0;
  }
  return fallback;
}

int32_t ReadInt(const flutter::EncodableMap& arguments, const char* key,
                int32_t fallback) {
  const auto it = arguments.find(Key(key));
  if (it == arguments.end()) return fallback;
  if (const int32_t* value = std::get_if<int32_t>(&it->second)) return *value;
  if (const int64_t* value = std::get_if<int64_t>(&it->second)) {
    return static_cast<int32_t>(*value);
  }
  return fallback;
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

  title_bar_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "jo_symbol_converter/window",
          &flutter::StandardMethodCodec::GetInstance());
  title_bar_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setTitleBar") {
          if (const auto* arguments =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            ApplyTitleBarTheme(*arguments);
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (title_bar_channel_) {
    title_bar_channel_->SetMethodCallHandler(nullptr);
    title_bar_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::ApplyTitleBarTheme(
    const flutter::EncodableMap& arguments) {
  HWND hwnd = GetHandle();
  if (!hwnd) return;

  const bool dark = ReadBool(arguments, "dark", false);
  const int32_t red =
      std::clamp(ReadInt(arguments, "red", 0), 0, 255);
  const int32_t green =
      std::clamp(ReadInt(arguments, "green", 0), 0, 255);
  const int32_t blue =
      std::clamp(ReadInt(arguments, "blue", 0), 0, 255);

  BOOL use_dark = dark ? TRUE : FALSE;
  DwmSetWindowAttribute(hwnd, kDwmwaUseImmersiveDarkMode, &use_dark,
                        sizeof(use_dark));

  // Turn off Mica / any system backdrop so the caption is a solid color.
  DWORD backdrop = kDwmSbtNone;
  DwmSetWindowAttribute(hwnd, kDwmwaSystemBackdropType, &backdrop,
                        sizeof(backdrop));
  BOOL mica = FALSE;
  DwmSetWindowAttribute(hwnd, kDwmwaMicaEffect, &mica, sizeof(mica));

  const COLORREF caption = RGB(red, green, blue);
  DwmSetWindowAttribute(hwnd, kDwmwaCaptionColor, &caption, sizeof(caption));
  const COLORREF text_color = dark ? RGB(255, 255, 255) : RGB(0, 0, 0);
  DwmSetWindowAttribute(hwnd, kDwmwaTextColor, &text_color,
                        sizeof(text_color));
  const COLORREF border = caption;
  DwmSetWindowAttribute(hwnd, kDwmwaBorderColor, &border, sizeof(border));

  SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_FRAMECHANGED);
  RedrawWindow(hwnd, nullptr, nullptr,
               RDW_INVALIDATE | RDW_FRAME | RDW_UPDATENOW);
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
