//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <cef_webview/cef_webview_plugin_c_api.h>
#include <desktop_drop/desktop_drop_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  CefWebviewPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("CefWebviewPluginCApi"));
  DesktopDropPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("DesktopDropPlugin"));
}
