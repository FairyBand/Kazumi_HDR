#ifndef RUNNER_LIFECYCLE_LOG_H_
#define RUNNER_LIFECYCLE_LOG_H_

#include <Windows.h>

#include <cstdio>
#include <iterator>
#include <mutex>
#include <string>

namespace kazumi {

// A deliberately small, synchronous crash-boundary log. It is only used for
// player/output lifecycle transitions, so write-through I/O cannot affect the
// frame loop. Keeping this native log separate from Dart logging ensures the
// final teardown stage survives an abrupt engine or GPU-process failure.
inline void LifecycleLog(const char* component, const std::string& message) {
  SYSTEMTIME time = {};
  ::GetLocalTime(&time);
  char line[2048] = {};
  const int length = std::snprintf(
      line, sizeof(line),
      "%04u-%02u-%02u %02u:%02u:%02u.%03u pid=%lu tid=%lu [%s] %s\r\n",
      time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute,
      time.wSecond, time.wMilliseconds, ::GetCurrentProcessId(),
      ::GetCurrentThreadId(), component, message.c_str());
  if (length <= 0) {
    return;
  }

  ::OutputDebugStringA(line);

  wchar_t app_data[MAX_PATH] = {};
  const DWORD app_data_length = ::GetEnvironmentVariableW(
      L"APPDATA", app_data, static_cast<DWORD>(std::size(app_data)));
  if (app_data_length == 0 || app_data_length >= std::size(app_data)) {
    return;
  }
  std::wstring app_dir =
      std::wstring(app_data) + L"\\com.example\\kazumi";
  std::wstring log_dir = app_dir + L"\\logs";
  ::CreateDirectoryW(app_dir.c_str(), nullptr);
  ::CreateDirectoryW(log_dir.c_str(), nullptr);
  const std::wstring path = log_dir + L"\\kazumi_native.log";

  static std::mutex log_mutex;
  std::lock_guard<std::mutex> lock(log_mutex);
  HANDLE file = ::CreateFileW(
      path.c_str(), FILE_APPEND_DATA,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  DWORD written = 0;
  ::WriteFile(file, line,
              static_cast<DWORD>(
                  length < static_cast<int>(sizeof(line)) ? length
                                                          : sizeof(line) - 1),
              &written, nullptr);
  ::CloseHandle(file);
}

}  // namespace kazumi

#endif  // RUNNER_LIFECYCLE_LOG_H_
