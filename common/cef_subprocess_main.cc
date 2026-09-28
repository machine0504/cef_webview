// CEF 子进程统一入口（render / gpu / utility / zygote 等）。
//
// 为什么必须用独立可执行：Flutter 插件在宿主 main() 启动后才加载，
// 无法在宿主 main 的最早期调用 CefExecuteProcess；而 CEF 通过重新拉起
// 「同一份可执行 + --type=xxx」来创建子进程，若直接复用宿主程序会再次
// 启动整个 Flutter 引擎导致崩溃。因此用一个极薄的 helper 可执行承载子进程。
//
// 三端产物：
//   Linux  : cef_webview_subprocess
//   Windows: cef_webview_subprocess.exe
//   macOS  : 打进各 *.app Helper（见 docs/PACKAGING.md）

#include "include/cef_app.h"
#include "cef_webview_app.h"

#if defined(_WIN32)
#include <windows.h>

int APIENTRY wWinMain(HINSTANCE hInstance,
                      HINSTANCE /*hPrevInstance*/,
                      LPWSTR /*lpCmdLine*/,
                      int /*nCmdShow*/) {
  // CEF 144 移除了 CefEnableHighDPISupport（DPI 感知改由可执行 manifest 声明）。
  // 子进程（render/gpu/utility）不创建可见窗口，无需显式 DPI 调用。
  CefMainArgs main_args(hInstance);
  CefRefPtr<cef_webview::CefWebviewApp> app(new cef_webview::CefWebviewApp());
  return CefExecuteProcess(main_args, app.get(), nullptr);
}

#elif defined(__APPLE__)  // macOS Helper（薄壳，运行期加载下载的 framework）

#include <cstdlib>
#include <pwd.h>
#include <string>
#include <unistd.h>

#include "include/wrapper/cef_library_loader.h"

namespace {

// 沙箱 Helper 的 $HOME 指向容器目录，不能用来拼 CEF 路径。
// 优先读主进程 CefInitialize 前注入的 CEF_WEBVIEW_ROOT；否则用真实用户目录。
std::string ResolveCefFrameworkBinary() {
  static const char kFwRel[] =
      "/Chromium Embedded Framework.framework/Chromium Embedded Framework";
  if (const char* root = getenv("CEF_WEBVIEW_ROOT")) {
    return std::string(root) + kFwRel;
  }
  const char* home = getenv("HOME");
  if (passwd* pw = getpwuid(getuid())) {
    if (pw->pw_dir && pw->pw_dir[0]) home = pw->pw_dir;
  }
  return std::string(home ? home : "") +
         "/Library/Application Support/cef_webview/cef/"
         "144.0.29-g0b1a012-chromium-144.0.7559.256" + kFwRel;
}

}  // namespace

int main(int argc, char* argv[]) {
  const std::string fw_bin = ResolveCefFrameworkBinary();
  if (cef_load_library(fw_bin.c_str()) != 1) return 1;

  CefMainArgs main_args(argc, argv);
  CefRefPtr<cef_webview::CefWebviewApp> app(new cef_webview::CefWebviewApp());
  int code = CefExecuteProcess(main_args, app.get(), nullptr);
  cef_unload_library();
  return code;
}

#else  // Linux

int main(int argc, char* argv[]) {
  CefMainArgs main_args(argc, argv);
  CefRefPtr<cef_webview::CefWebviewApp> app(new cef_webview::CefWebviewApp());
  return CefExecuteProcess(main_args, app.get(), nullptr);
}

#endif
