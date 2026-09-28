# Flutter Linux 插件构建：cef_webview（CEF 99 + OSR）
#
# 架构：CEF 封装进独立 libcef_webview_engine.so，插件运行时用 dlopen(RTLD_DEEPBIND)
# 加载，使 CEF 与 Flutter engine（同基于 Chromium）的全局符号/分配器隔离，
# 避免 CefInitialize 死锁。插件本身不链接 CEF。
cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "cef_webview")
# 同时启用 C：glibc_compat_math.c（aarch64 glibc 2.29 兼容垫片）是 C 源。
project(${PROJECT_NAME} LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(PLUGIN_NAME "cef_webview_plugin")

# --------------------------------------------------------------------------
# CEF
# --------------------------------------------------------------------------
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
include(DownloadCEF)
# 按目标架构选择 CEF 分发包：aarch64（统信/麒麟等国产 ARM）用 linuxarm64，其余 linux64。
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64|ARM64")
  download_cef("linuxarm64")
  # CEF 的 cmake/cef_variables.cmake 在 Linux 下仅按指针大小判定架构（8 字节即 x86_64），
  # 不识别 aarch64，会错误加入 -march=x86-64。这里显式声明，供其 add_subdirectory 使用。
  set(PROJECT_ARCH "arm64")
else()
  download_cef("linux64")
endif()
set(CEF_INCLUDE_DIR "${CEF_ROOT}")
set(CEF_BIN_DIR "${CEF_ROOT}/Release")
set(CEF_RES_DIR "${CEF_ROOT}/Resources")
message(STATUS "[CEF] CEF_ROOT=${CEF_ROOT}")
add_subdirectory("${CEF_ROOT}" "${CMAKE_BINARY_DIR}/cef" EXCLUDE_FROM_ALL)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

set(COMMON_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../common")

# --------------------------------------------------------------------------
# 1) 独立 CEF 引擎 .so（含 CEF；插件运行时 dlopen+DEEPBIND 加载）
# --------------------------------------------------------------------------
add_library(cef_webview_engine SHARED
  "${COMMON_DIR}/cef_engine_api.cc"
  "${COMMON_DIR}/cef_webview_app.cc"
  "${COMMON_DIR}/cef_webview_handler.cc"
  "${COMMON_DIR}/cef_browser_manager.cc"
  # glibc 2.29 数学符号兼容（仅 aarch64 旧 glibc 生效；CEF arm64 库引用 exp@GLIBC_2.29）
  "${COMMON_DIR}/glibc_compat_math.c"
)
set_target_properties(cef_webview_engine PROPERTIES
  CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)
target_include_directories(cef_webview_engine PRIVATE
  "${COMMON_DIR}" "${COMMON_DIR}/include" "${CEF_INCLUDE_DIR}")
target_link_libraries(cef_webview_engine PRIVATE
  libcef_dll_wrapper "${CEF_BIN_DIR}/libcef.so" dl pthread m)
# rpath 指向 $ORIGIN(=bundle/lib)，并用 DT_RPATH（CEF ICU/资源查找依赖）。
set_target_properties(cef_webview_engine PROPERTIES
  INSTALL_RPATH "$ORIGIN" BUILD_WITH_INSTALL_RPATH TRUE)
target_link_options(cef_webview_engine PRIVATE -Wl,--disable-new-dtags)
# aarch64：声明 GLIBC_2.29 版本节点，使 glibc_compat_math.c 提供的 exp@GLIBC_2.29 等
# 版本符号在 -shared 链接时可定义（满足 CEF arm64 库的版本化引用）。
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64|ARM64")
  target_link_options(cef_webview_engine PRIVATE
    "-Wl,--version-script=${COMMON_DIR}/glibc_compat_229.ver")
endif()

# --------------------------------------------------------------------------
# 2) Flutter 插件（不链接 CEF，仅 dlopen 引擎）
# --------------------------------------------------------------------------
add_library(${PLUGIN_NAME} SHARED "cef_webview_plugin.cc")
apply_standard_settings(${PLUGIN_NAME})
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${COMMON_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/..")
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter PkgConfig::GTK dl)
set_target_properties(${PLUGIN_NAME} PROPERTIES INSTALL_RPATH "$ORIGIN")
add_dependencies(${PLUGIN_NAME} cef_webview_engine)

# --------------------------------------------------------------------------
# 3) CEF 子进程可执行
# --------------------------------------------------------------------------
add_executable(cef_webview_subprocess
  "${COMMON_DIR}/cef_subprocess_main.cc"
  "${COMMON_DIR}/cef_webview_app.cc"
  # glibc 2.29 数学符号兼容（仅 aarch64 旧 glibc 生效）
  "${COMMON_DIR}/glibc_compat_math.c"
)
set_target_properties(cef_webview_subprocess PROPERTIES CXX_STANDARD 17)
target_include_directories(cef_webview_subprocess PRIVATE
  "${COMMON_DIR}" "${COMMON_DIR}/include" "${CEF_INCLUDE_DIR}")
target_link_libraries(cef_webview_subprocess PRIVATE
  libcef_dll_wrapper "${CEF_BIN_DIR}/libcef.so" dl pthread m)
# 关键：rpath 必须指向 $ORIGIN（运行时即 bundle/lib，含 libcef.so 与 icudtl.dat），
# 而非构建期的 Release 目录（那里没有 icudtl.dat）。用 BUILD_WITH_INSTALL_RPATH
# 让 bundled 复制的产物即带 $ORIGIN。CEF ICU 查找依赖 DT_RPATH（见文档）。
set_target_properties(cef_webview_subprocess PROPERTIES
  INSTALL_RPATH "$ORIGIN" BUILD_WITH_INSTALL_RPATH TRUE)
target_link_options(cef_webview_subprocess PRIVATE -Wl,--disable-new-dtags)

# --------------------------------------------------------------------------
# 4) 随包分发文件（平铺到 bundle/lib/）
# --------------------------------------------------------------------------
set(CEF_LOCALES "zh-CN.pak" "en-US.pak")
set(_cef_locale_files "")
foreach(_loc ${CEF_LOCALES})
  list(APPEND _cef_locale_files "${CEF_RES_DIR}/locales/${_loc}")
endforeach()

# 按「谁的代码，跟谁的版本走」切分：
#
#   CEF 分发物（libcef.so / *.pak / icudtl.dat / locales / sandbox）
#     → 留在版本化的下载包里，只随 CEF 版本变（见 docs/RUNTIME_HOSTING.md）。
#
#   我们自己的代码（common/ 全部实现：浏览器管理、鼠标键盘、IME、拖拽、
#   OnFileDialog、渲染回调）编在 cef_webview_engine 与 cef_webview_subprocess 里
#     → 必须随 app 每次构建分发。
#
# 这两者曾被一起塞进「CEF 运行时下载包」。那个包按 CEF 版本节奏重建，于是 app 更新
# 之后机器上仍在跑几个月前的 common/：改了不生效，而且没有任何提示——一次拖拽崩溃
# 排查中，连着三版 C++ 修改都没能到达目标机，日志永远是空的。此处把我们的产物交还
# 给 app 构建，杜绝这类静默失配。
#
# 运行位置仍需与 libcef.so 并排（引擎靠 DT_RPATH=$ORIGIN 找它），故 bundle/lib/ 里
# 的这两个产物由 deb 的 postinst 落到 CEF 目录，见 embed_assets_into_deb.sh。
set(cef_webview_bundled_libraries
  "$<TARGET_FILE:cef_webview_engine>"
  "$<TARGET_FILE:cef_webview_subprocess>"
  PARENT_SCOPE)
