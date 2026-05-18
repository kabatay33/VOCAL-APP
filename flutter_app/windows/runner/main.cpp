#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

// --- Single Instance Enforcement ---
// Uygulamanın yalnızca bir kopyasının çalışmasını sağlar.
// İkinci kopya başlatılırsa mevcut pencere ön plana getirilir.
// Pencere tray'de gizliyse (hidden) de görünür hale getirir.
static bool BringExistingInstanceToFront() {
  // Flutter Windows runner'ın kayıtlı pencere sınıfı adı
  const wchar_t* kFlutterClass = L"FLUTTER_RUNNER_WIN32_WINDOW";
  HWND hwnd = ::FindWindowW(kFlutterClass, nullptr);
  if (hwnd == nullptr) return false;

  // 1) Tray'e gizlenmis pencereyi gorunur yap (SW_HIDE -> SW_SHOW)
  if (!::IsWindowVisible(hwnd)) {
    ::ShowWindow(hwnd, SW_SHOW);
  }

  // 2) Simge durumundaysa geri yukle (minimized)
  if (::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  }

  // 3) Pencereyi ön plana getir — Windows foreground stealing korumasini
  // bypass etmek için AttachThreadInput trigi: hedef pencerenin thread
  // input'una baglanip SetForegroundWindow cagir, sonra cozul.
  DWORD foregroundThread =
      ::GetWindowThreadProcessId(::GetForegroundWindow(), nullptr);
  DWORD targetThread = ::GetWindowThreadProcessId(hwnd, nullptr);
  DWORD currentThread = ::GetCurrentThreadId();

  bool attached1 = false, attached2 = false;
  if (foregroundThread != currentThread) {
    attached1 = ::AttachThreadInput(currentThread, foregroundThread, TRUE);
  }
  if (targetThread != currentThread && targetThread != foregroundThread) {
    attached2 = ::AttachThreadInput(currentThread, targetThread, TRUE);
  }

  ::BringWindowToTop(hwnd);
  ::SetForegroundWindow(hwnd);
  ::SetFocus(hwnd);

  if (attached1) ::AttachThreadInput(currentThread, foregroundThread, FALSE);
  if (attached2) ::AttachThreadInput(currentThread, targetThread, FALSE);

  // 4) Eger hala arka plandaysa flash ile dikkat cek
  if (::GetForegroundWindow() != hwnd) {
    FLASHWINFO fi{};
    fi.cbSize = sizeof(fi);
    fi.hwnd = hwnd;
    fi.dwFlags = FLASHW_TRAY | FLASHW_TIMERNOFG;
    fi.uCount = 5;
    fi.dwTimeout = 0;
    ::FlashWindowEx(&fi);
  }
  return true;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // --- Single Instance Check ---
  // İsimli mutex ile tek örnek kontrolü: ikinci çalıştırmada
  // mevcut pencereyi öne getir ve çık.
  HANDLE hMutex = ::CreateMutexW(nullptr, TRUE, L"LocalHub_SingleInstanceMutex_v1");
  if (hMutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    // Başka bir kopya zaten çalışıyor
    BringExistingInstanceToFront();
    ::CloseHandle(hMutex);
    return 0;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"LocalHub", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
