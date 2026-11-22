#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <wincrypt.h>
#include <array>
#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {
constexpr wchar_t kUninstallKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\"
    L"{5D33876C-42D7-4DBB-B769-859706D4D663}_is1";

// An enrollment receipt can only be opened by its originating Windows user.
// Its DPAPI entropy is bound to this format and the selected TNote room.
std::optional<std::vector<uint8_t>> OpenEnrollment(
    const flutter::EncodableValue* arguments) {
  const auto* args = arguments ? std::get_if<flutter::EncodableList>(arguments) : nullptr;
  if (!args || args->size() != 2) return std::nullopt;
  const auto* room = std::get_if<std::string>(&args->at(0));
  const auto* cipher = std::get_if<std::vector<uint8_t>>(&args->at(1));
  if (!room || room->size() != 64 ||
      room->find_first_not_of("0123456789abcdef") != std::string::npos ||
      !cipher || cipher->empty() || cipher->size() > 4096) return std::nullopt;
  std::string purpose = "TNote/migration-key/v1/" + *room;
  DATA_BLOB entropy{static_cast<DWORD>(purpose.size()),
                    reinterpret_cast<BYTE*>(purpose.data())};
  DATA_BLOB encrypted{static_cast<DWORD>(cipher->size()),
                      const_cast<BYTE*>(cipher->data())};
  DATA_BLOB plain{};
  if (!::CryptUnprotectData(&encrypted, nullptr, &entropy, nullptr, nullptr,
                            CRYPTPROTECT_UI_FORBIDDEN, &plain)) return std::nullopt;
  std::optional<std::vector<uint8_t>> key;
  if (plain.cbData == 32) key.emplace(plain.pbData, plain.pbData + plain.cbData);
  if (plain.pbData) {
    ::SecureZeroMemory(plain.pbData, plain.cbData);
    ::LocalFree(plain.pbData);
  }
  return key;
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
  install_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "tnote/windows_installation",
          &flutter::StandardMethodCodec::GetInstance());
  install_channel_->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "openMigrationEnrollment") {
      auto key = OpenEnrollment(call.arguments());
      if (key) {
        result->Success(flutter::EncodableValue(*key));
        ::SecureZeroMemory(key->data(), key->size());
      } else {
        result->Error("migration_enrollment", "参加情報を確認できません。");
      }
      return;
    }
    if (call.method_name() != "getInstallDirectory") {
      result->NotImplemented();
      return;
    }
    std::array<wchar_t, 32768> path{};
    DWORD bytes = static_cast<DWORD>(sizeof(path));
    if (::RegGetValueW(HKEY_CURRENT_USER, kUninstallKey, L"InstallLocation",
                       RRF_RT_REG_SZ, nullptr, path.data(), &bytes) == ERROR_SUCCESS) {
      result->Success(flutter::EncodableValue(Utf8FromUtf16(path.data())));
    } else {
      result->Success();
    }
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  install_channel_.reset();
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
