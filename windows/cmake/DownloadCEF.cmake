# 解析 / 下载 CEF 预编译二进制分发包（Windows）。
#
# 优先级：
#   1) -DCEF_ROOT= / 环境变量 CEF_ROOT
#   2) 仓库 third_party/cef/cef_binary_${VERSION}_${platform}_minimal（多候选路径）
#   3) CMAKE_BINARY_DIR/cef 缓存
#   4) Spotify CDN 下载（TLS 失败时自动回退；并清理 0 字节残包）
#
# 注意：Windows 上 CMake 的 REALPATH / file(REAL_PATH) 往往**不会**解开 Flutter 的
# .plugin_symlinks，因此不能只用「插件目录/../../third_party」。必须同时用
# CMAKE_SOURCE_DIR（通常是 desktop/windows）回退到仓库根。

set(CEF_VERSION "144.0.29+g0b1a012+chromium-144.0.7559.256"
    CACHE STRING "CEF 分支版本")

function(download_cef platform)
  if(DEFINED CEF_ROOT AND NOT "${CEF_ROOT}" STREQUAL "" AND EXISTS "${CEF_ROOT}/include/cef_version.h")
    message(STATUS "[CEF] 使用已有 CEF_ROOT=${CEF_ROOT}")
    set(CEF_ROOT "${CEF_ROOT}" PARENT_SCOPE)
    return()
  endif()
  if(DEFINED ENV{CEF_ROOT} AND EXISTS "$ENV{CEF_ROOT}/include/cef_version.h")
    message(STATUS "[CEF] 使用环境变量 CEF_ROOT=$ENV{CEF_ROOT}")
    set(CEF_ROOT "$ENV{CEF_ROOT}" PARENT_SCOPE)
    return()
  endif()

  set(_name "cef_binary_${CEF_VERSION}_${platform}_minimal")

  # 多候选：兼容 symlink 未解析 / 不同工作树布局
  set(_candidates "")
  # A) 宿主 App 的 windows/ 上两级 = 仓库根（Flutter Windows 工程最可靠）
  if(DEFINED CMAKE_SOURCE_DIR)
    get_filename_component(_from_app "${CMAKE_SOURCE_DIR}/../.." ABSOLUTE)
    list(APPEND _candidates "${_from_app}/third_party/cef/${_name}")
  endif()
  # B) 插件目录上两级（Linux/macOS 或已解析 symlink 时有效）
  get_filename_component(_plugin_root "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
  get_filename_component(_from_plugin "${_plugin_root}/../.." ABSOLUTE)
  list(APPEND _candidates "${_from_plugin}/third_party/cef/${_name}")
  # C) 若当前在 .plugin_symlinks 下，尝试读 junction/symlink 目标（Windows）
  if(WIN32 AND EXISTS "${_plugin_root}")
    execute_process(
      COMMAND cmd /c "for %I in (\"${_plugin_root}\") do @echo %~fI"
      OUTPUT_VARIABLE _plugin_full
      OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_QUIET)
    # PowerShell Resolve-Path - 解析 SymbolicLink Target
    execute_process(
      COMMAND powershell -NoProfile -Command
        "(Get-Item -LiteralPath '${_plugin_root}').Target"
      OUTPUT_VARIABLE _link_target
      OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_QUIET)
    if(_link_target)
      # Target 可能是列表；取第一行
      string(REGEX REPLACE "[\r\n].*" "" _link_target "${_link_target}")
      if(NOT "${_link_target}" STREQUAL "")
        get_filename_component(_from_link "${_link_target}/../.." ABSOLUTE)
        list(APPEND _candidates "${_from_link}/third_party/cef/${_name}")
      endif()
    endif()
  endif()

  foreach(_c IN LISTS _candidates)
    if(EXISTS "${_c}/include/cef_version.h")
      message(STATUS "[CEF] 使用本地 third_party: ${_c}")
      set(CEF_ROOT "${_c}" PARENT_SCOPE)
      return()
    endif()
  endforeach()
  message(STATUS "[CEF] 未找到本地 third_party，候选: ${_candidates}")

  set(_dl_dir "${CMAKE_BINARY_DIR}/cef")
  set(_root "${_dl_dir}/${_name}")
  if(EXISTS "${_root}/include/cef_version.h")
    message(STATUS "[CEF] 复用已下载: ${_root}")
    set(CEF_ROOT "${_root}" PARENT_SCOPE)
    return()
  endif()

  string(REPLACE "+" "%2B" _ver_url "${CEF_VERSION}")
  set(_url "https://cef-builds.spotifycdn.com/cef_binary_${_ver_url}_${platform}_minimal.tar.bz2")
  set(_archive "${_dl_dir}/${_name}.tar.bz2")
  file(MAKE_DIRECTORY "${_dl_dir}")

  # 上次 SSL 失败常留下残包
  if(EXISTS "${_archive}")
    file(SIZE "${_archive}" _asz)
    if(_asz LESS 1024)
      message(STATUS "[CEF] 删除损坏的缓存包 (${_asz} bytes): ${_archive}")
      file(REMOVE "${_archive}")
    endif()
  endif()

  if(NOT EXISTS "${_archive}")
    message(STATUS "[CEF] 下载 ${_url}")
    file(DOWNLOAD "${_url}" "${_archive}" SHOW_PROGRESS TLS_VERIFY ON STATUS _st)
    list(GET _st 0 _code)
    if(NOT _code EQUAL 0)
      message(WARNING "[CEF] TLS 校验下载失败 (${_st})，尝试 TLS_VERIFY OFF …")
      file(REMOVE "${_archive}")
      file(DOWNLOAD "${_url}" "${_archive}" SHOW_PROGRESS TLS_VERIFY OFF STATUS _st)
      list(GET _st 0 _code)
    endif()
    if(NOT _code EQUAL 0)
      message(WARNING "[CEF] CMake 下载仍失败 (${_st})，尝试 curl …")
      file(REMOVE "${_archive}")
      find_program(_curl curl)
      if(_curl)
        execute_process(
          COMMAND "${_curl}" -L --retry 3 --connect-timeout 30
                  --ssl-no-revoke -o "${_archive}" "${_url}"
          RESULT_VARIABLE _curl_rv)
        if(NOT _curl_rv EQUAL 0)
          execute_process(
            COMMAND "${_curl}" -L -k --retry 3 --connect-timeout 30
                    -o "${_archive}" "${_url}"
            RESULT_VARIABLE _curl_rv)
        endif()
        if(_curl_rv EQUAL 0 AND EXISTS "${_archive}")
          file(SIZE "${_archive}" _asz)
          if(_asz GREATER 1024)
            set(_code 0)
          endif()
        endif()
      endif()
    endif()
    if(NOT _code EQUAL 0)
      list(GET _candidates 0 _hint)
      message(FATAL_ERROR
        "[CEF] 下载失败 (${_st})。请将 minimal 包解压到:\n"
        "  ${_hint}\n"
        "或设置环境变量 CEF_ROOT=该目录，或 -DCEF_ROOT=。\n"
        "官方包: ${_url}")
    endif()
  endif()

  message(STATUS "[CEF] 解压 ${_archive}")
  file(ARCHIVE_EXTRACT INPUT "${_archive}" DESTINATION "${_dl_dir}")
  if(NOT EXISTS "${_root}/include/cef_version.h")
    message(FATAL_ERROR "[CEF] 解压后未找到: ${_root}")
  endif()
  set(CEF_ROOT "${_root}" PARENT_SCOPE)
endfunction()
