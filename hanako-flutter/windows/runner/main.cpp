#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

// =====================================================================
// 性能优化（参考 flutter-migration-plan/性能优化复盘-20260207.md §5.3）
//
// Nvidia Optimus / AMD PowerXpress 笔记本通常默认走集成显卡。
// 通过导出这两个符号，可让驱动识别本程序为「需要高性能 GPU」。
//
// 不是环境变量，是 PE 导出符号——驱动通过 GetProcAddress 检测。
// =====================================================================
extern "C" {
__declspec(dllexport) DWORD NvOptimusEnablement = 0x00000001;
__declspec(dllexport) int AmdPowerXpressRequestHighPerformance = 1;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // =====================================================================
  // 性能优化（参考 flutter-migration-plan/性能优化复盘-20260207.md §5.3）
  //
  // 显式锁定 UI isolate 走独立线程，与平台线程解耦，减少互相挤占造成的帧抖动。
  //
  // 注意：Flutter 当前 Default 行为正是 RunOnSeparateThread（见 dart_project.h
  // UIThreadPolicy::Default 注释），但官方计划在未来版本切到 RunOnPlatformThread。
  // 显式锁定可避免升级 Flutter 时静默改变线程策略。
  // 该 API 未来可能移除——升级 Flutter 时复测 Windows 帧稳定性，并关注 embedder 变更。
  // =====================================================================
  project.set_ui_thread_policy(flutter::UIThreadPolicy::RunOnSeparateThread);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Hanako", origin, size)) {
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
