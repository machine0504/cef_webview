#include "include/cef_webview/cef_webview_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "cef_webview_plugin.h"

void CefWebviewPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  cef_webview::CefWebviewPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
