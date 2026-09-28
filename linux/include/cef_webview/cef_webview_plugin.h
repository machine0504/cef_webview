#ifndef FLUTTER_PLUGIN_CEF_WEBVIEW_PLUGIN_H_
#define FLUTTER_PLUGIN_CEF_WEBVIEW_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FLUTTER_PLUGIN_EXPORT
#endif

typedef struct _CefWebviewPlugin CefWebviewPlugin;
typedef struct {
  GObjectClass parent_class;
} CefWebviewPluginClass;

FLUTTER_PLUGIN_EXPORT GType cef_webview_plugin_get_type();

FLUTTER_PLUGIN_EXPORT void cef_webview_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

// 必须在 runner main() 最早期（gtk_init / Flutter engine 之前、进程仍单线程时）
// 调用，完成 CefInitialize。否则多线程环境下 CefInitialize 会死锁（Linux 必需）。
FLUTTER_PLUGIN_EXPORT void cef_webview_plugin_pre_initialize(void);

G_END_DECLS

#endif  // FLUTTER_PLUGIN_CEF_WEBVIEW_PLUGIN_H_
