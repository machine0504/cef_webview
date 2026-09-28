# 解析 / 下载 CEF 预编译二进制分发包（Linux）。
#
# 优先级：
#   1) 命令行 -DCEF_ROOT=/abs/path（指向你自行编译/解压的 CEF 分发目录）；
#   2) 环境变量 CEF_ROOT；
#   3) 仓库 third_party/cef/cef_binary_${VERSION}_${platform}_minimal（多候选路径）；
#   4) 自动运行 tools/bootstrap_cef_linux.sh（可用 CEF_SDK_ARCHIVE 指定本地 .tar.bz2）；
#   5) CMAKE_BINARY_DIR/cef 缓存；
#   6) Spotify CDN 下载（需要外网）。
#
# 注意：Flutter Linux 构建时本文件经 ephemeral/.plugin_symlinks/cef_webview/linux
# 引入，相对路径 ../../../third_party 会落到 ephemeral/ 而非仓库根。必须同时用
# CMAKE_SOURCE_DIR（通常是 desktop/linux）回退到仓库根（与 Windows DownloadCEF 一致）。
#
# CEF 分发目录应包含：include/  libcef_dll/  Release/  Resources/  cmake/
#
# 用法：
#   include(cmake/DownloadCEF.cmake)
#   download_cef("linux64")   # linux64 / linuxarm64 / …

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

  # 多候选：兼容 .plugin_symlinks 未解析到真实插件路径时的布局
  set(_candidates "")
  # A) 宿主 App 的 linux/ 上两级 = 仓库根（Flutter Linux 工程最可靠）
  if(DEFINED CMAKE_SOURCE_DIR)
    get_filename_component(_from_app "${CMAKE_SOURCE_DIR}/../.." ABSOLUTE)
    list(APPEND _candidates "${_from_app}/third_party/cef/${_name}")
  endif()
  # B) 插件目录上两级（已解析 symlink 时有效：package/ 旁的 third_party）
  get_filename_component(_plugin_root "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
  get_filename_component(_from_plugin "${_plugin_root}/../.." ABSOLUTE)
  list(APPEND _candidates "${_from_plugin}/third_party/cef/${_name}")
  # C) 读 symlink 目标再上溯（Linux readlink -f）
  if(EXISTS "${_plugin_root}")
    execute_process(
      COMMAND readlink -f "${_plugin_root}"
      OUTPUT_VARIABLE _link_target
      OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_QUIET)
    if(_link_target AND NOT "${_link_target}" STREQUAL "")
      get_filename_component(_from_link "${_link_target}/../.." ABSOLUTE)
      list(APPEND _candidates "${_from_link}/third_party/cef/${_name}")
    endif()
  endif()

  foreach(_c IN LISTS _candidates)
    if(EXISTS "${_c}/include/cef_version.h" AND EXISTS "${_c}/CMakeLists.txt")
      message(STATUS "[CEF] 使用本地 third_party: ${_c}")
      set(CEF_ROOT "${_c}" PARENT_SCOPE)
      return()
    endif()
  endforeach()
  message(STATUS "[CEF] 未找到本地 third_party，候选: ${_candidates}")

  set(_bootstrap "${CMAKE_CURRENT_SOURCE_DIR}/../tools/bootstrap_cef_linux.sh")
  # symlink 解析后的真实插件 tools/ 更可靠
  if(_link_target AND EXISTS "${_link_target}/tools/bootstrap_cef_linux.sh")
    set(_bootstrap "${_link_target}/tools/bootstrap_cef_linux.sh")
  endif()
  if(EXISTS "${_bootstrap}")
    message(STATUS "[CEF] third_party 未找到，尝试 bootstrap_cef_linux.sh …")
    get_filename_component(_boot_dir "${_bootstrap}" DIRECTORY)
    execute_process(
      COMMAND bash "${_bootstrap}"
      WORKING_DIRECTORY "${_boot_dir}"
      RESULT_VARIABLE _boot_rv
      OUTPUT_VARIABLE _boot_out
      ERROR_VARIABLE _boot_err)
    if(_boot_out)
      message(STATUS "${_boot_out}")
    endif()
    if(_boot_err)
      message(STATUS "${_boot_err}")
    endif()
    foreach(_c IN LISTS _candidates)
      if(_boot_rv EQUAL 0 AND EXISTS "${_c}/include/cef_version.h" AND EXISTS "${_c}/CMakeLists.txt")
        message(STATUS "[CEF] bootstrap 成功: ${_c}")
        set(CEF_ROOT "${_c}" PARENT_SCOPE)
        return()
      endif()
    endforeach()
  endif()

  set(_dl_dir "${CMAKE_BINARY_DIR}/cef")
  set(_root "${_dl_dir}/${_name}")

  if(EXISTS "${_root}/include/cef_version.h" AND EXISTS "${_root}/CMakeLists.txt")
    message(STATUS "[CEF] 复用已下载: ${_root}")
    set(CEF_ROOT "${_root}" PARENT_SCOPE)
    return()
  endif()

  # URL 中的 '+' 需转义为 %2B
  string(REPLACE "+" "%2B" _ver_url "${CEF_VERSION}")
  set(_url "https://cef-builds.spotifycdn.com/cef_binary_${_ver_url}_${platform}_minimal.tar.bz2")
  set(_archive "${_dl_dir}/${_name}.tar.bz2")

  message(STATUS "[CEF] 下载 ${_url}")
  file(MAKE_DIRECTORY "${_dl_dir}")
  file(DOWNLOAD "${_url}" "${_archive}"
       SHOW_PROGRESS TLS_VERIFY ON STATUS _st)
  list(GET _st 0 _code)
  if(NOT _code EQUAL 0)
    message(FATAL_ERROR
      "[CEF] 下载失败 (${_st})。内网请先将官方 minimal 包放入 third_party/cef/，"
      "或运行: package/cef_webview/tools/bootstrap_cef_linux.sh --archive /path/to/${_name}.tar.bz2"
      "，或通过 -DCEF_ROOT= 指定本地分发目录。")
  endif()

  message(STATUS "[CEF] 解压 ${_archive}")
  file(ARCHIVE_EXTRACT INPUT "${_archive}" DESTINATION "${_dl_dir}")
  if(NOT EXISTS "${_root}/include/cef_version.h")
    message(FATAL_ERROR "[CEF] 解压后未找到分发目录: ${_root}")
  endif()
  set(CEF_ROOT "${_root}" PARENT_SCOPE)
endfunction()
