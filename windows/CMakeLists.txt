# Flutter Windows 插件构建：cef_webview（CEF 99 + OSR）
cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "cef_webview")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "cef_webview_plugin")

# --------------------------------------------------------------------------
# CEF：匹配 Flutter 的动态 CRT(/MD)，避免与 libcef 运行库冲突
# --------------------------------------------------------------------------
set(CEF_RUNTIME_LIBRARY_FLAG "/MD" CACHE STRING "" FORCE)

# 运行时已固定 no_sandbox=true（见 common/cef_browser_manager.cc），且本插件未链接
# cef_sandbox.lib。这里在 CEF 的 cmake(option USE_SANDBOX ON) 生效前关闭沙箱，主要为：
#   1) 避免 USE_SANDBOX 在 Debug 下给 libcef_dll_wrapper 注入 _HAS_ITERATOR_DEBUGGING=0
#      (_ITERATOR_DEBUG_LEVEL=0)，与 Flutter wrapper(_ITERATOR_DEBUG_LEVEL=2) 链接时
#      冲突 → LNK2038/LNK1319，导致 Debug(flutter run) 构建失败；
#   2) 与运行时 no_sandbox=true 保持一致，并省去对 cef_sandbox.lib 的依赖。
# 用 CACHE FORCE 以覆盖既有构建缓存中的默认 ON。
set(USE_SANDBOX OFF CACHE BOOL "CEF sandbox disabled (runtime uses no_sandbox)" FORCE)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
include(DownloadCEF)
download_cef("windows64")
set(CEF_INCLUDE_DIR "${CEF_ROOT}")
set(CEF_BIN_DIR "${CEF_ROOT}/Release")
set(CEF_RES_DIR "${CEF_ROOT}/Resources")
add_subdirectory("${CEF_ROOT}" "${CMAKE_BINARY_DIR}/cef" EXCLUDE_FROM_ALL)

set(COMMON_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../common")

# --------------------------------------------------------------------------
# 插件 DLL
# --------------------------------------------------------------------------
add_library(${PLUGIN_NAME} SHARED
  "cef_webview_plugin_c_api.cpp"
  "cef_webview_plugin.cpp"
  "${COMMON_DIR}/cef_webview_app.cc"
  "${COMMON_DIR}/cef_webview_handler.cc"
  "${COMMON_DIR}/cef_browser_manager.cc"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL NOMINMAX)
# Flutter APPLY_STANDARD_SETTINGS 带 /WX；MSVC 将 getenv 标为 C4996，需单独放行。
target_compile_options(${PLUGIN_NAME} PRIVATE /wd"4996")

target_include_directories(${PLUGIN_NAME} PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${COMMON_DIR}"
  "${COMMON_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/.."
  "${CEF_INCLUDE_DIR}"
)
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  libcef_dll_wrapper
  "${CEF_BIN_DIR}/libcef.lib"
  delayimp                       # /DELAYLOAD 所需的辅助库
)

# libcef.dll 延迟加载：使插件 DLL 启动时不立即解析 libcef.dll（CEF 运行时改为按需
# 下载，启动时可能尚不存在）。首次调用 CEF 导出符号时才加载，届时插件已通过
# AddDllDirectory(cefRoot) 把运行时目录加入 DLL 搜索路径（见 cef_webview_plugin.cpp）。
target_link_options(${PLUGIN_NAME} PRIVATE "/DELAYLOAD:libcef.dll")

# --------------------------------------------------------------------------
# 子进程可执行
# --------------------------------------------------------------------------
add_executable(cef_webview_subprocess WIN32
  "${COMMON_DIR}/cef_subprocess_main.cc"
  "${COMMON_DIR}/cef_webview_app.cc"
)
set_target_properties(cef_webview_subprocess PROPERTIES CXX_STANDARD 17)
target_include_directories(cef_webview_subprocess PRIVATE
  "${COMMON_DIR}" "${COMMON_DIR}/include" "${CEF_INCLUDE_DIR}")
target_link_libraries(cef_webview_subprocess PRIVATE
  libcef_dll_wrapper "${CEF_BIN_DIR}/libcef.lib")

# --------------------------------------------------------------------------
# 随包分发文件（Flutter 复制到 runner exe 同目录）
# --------------------------------------------------------------------------
set(CEF_LOCALES "zh-CN.pak" "en-US.pak")
set(_cef_locale_files "")
foreach(_loc ${CEF_LOCALES})
  list(APPEND _cef_locale_files "${CEF_RES_DIR}/locales/${_loc}")
endforeach()

# CEF 运行时（libcef.dll / 资源 / subprocess）不再随 app 打包，改为运行期从自有
# 服务器按平台下载到 %LOCALAPPDATA%\cef_webview\cef\<ver>（见 docs/RUNTIME_HOSTING.md）。
# cef_webview_subprocess 仍会被构建——其产物由 tools/make_cef_runtime.sh 收进
# 「下载包」，而非 bundle 进 app。
set(cef_webview_bundled_libraries "" PARENT_SCOPE)
