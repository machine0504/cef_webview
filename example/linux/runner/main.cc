#include "my_application.h"

// CEF 必须在进程仍是单线程时初始化（Flutter engine 起来后再 init 会死锁）。
extern "C" void cef_webview_plugin_pre_initialize(void);

int main(int argc, char** argv) {
  cef_webview_plugin_pre_initialize();

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
