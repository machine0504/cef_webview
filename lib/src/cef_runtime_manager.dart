import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// CEF 运行时（libcef / framework / 资源）的就绪状态。
///
/// 架构：CEF 大体积运行时不随 App 打包，改为运行期按平台-架构从自有服务器下载到
/// 用户数据目录。本管理器负责「探测就绪 / 下载 / 校验 / 原子安装」，并向 UI 暴露
/// 状态流；具体加载由各端 native 插件从 `cefRoot` 目录完成。
enum CefRuntimeStatus {
  /// 尚未探测。
  unknown,

  /// 本地无可用运行时，需要下载。
  notInstalled,

  /// 正在下载。
  downloading,

  /// 正在校验 sha256。
  verifying,

  /// 正在解压安装。
  extracting,

  /// 已就绪，可加载（[CefRuntimeState.cefRoot] 为绝对目录）。
  ready,

  /// 出错（[CefRuntimeState.message] 为原因）。
  error,
}

/// CEF 运行时状态快照。
@immutable
class CefRuntimeState {
  const CefRuntimeState(
    this.status, {
    this.progress = 0,
    this.message,
    this.cefRoot,
    this.totalBytes,
  });

  final CefRuntimeStatus status;

  /// 下载进度 0..1（仅 [CefRuntimeStatus.downloading] 有意义）。
  final double progress;

  /// 出错原因 / 提示信息。
  final String? message;

  /// 就绪时的运行时目录（含 libcef / framework / 资源）。
  final String? cefRoot;

  /// 当前平台下载包的总字节数（来自 manifest 的 `size`）；未知时为 null。
  /// 仅在 [CefRuntimeStatus.downloading] 阶段有意义，供 UI 显示真实体积。
  final int? totalBytes;

  bool get isReady => status == CefRuntimeStatus.ready;

  @override
  String toString() =>
      'CefRuntimeState($status, progress=$progress, cefRoot=$cefRoot, message=$message)';
}

/// CEF 运行时下载 / 安装 / 就绪探测管理器（进程级单例）。
///
/// 用法（App 启动早期）：
/// ```dart
/// CefRuntimeManager.instance.configure(
///   manifestUrl: 'https://你们域名/cef/manifest.json',
/// );
/// final root = await CefRuntimeManager.instance.resolveReadyRoot();
/// if (root == null) {
///   // 未就绪：UI 显示下载入口/温馨提示；用户触发 download()，完成后引导重启。
/// } else {
///   await CefWebview.ensureInitialized(); // 内部会把 root 作为 cefRoot 传给 native
/// }
/// ```
class CefRuntimeManager {
  CefRuntimeManager._();

  static final CefRuntimeManager instance = CefRuntimeManager._();

  /// 客户端内置的期望 CEF 版本，必须与服务器 manifest 的 `cefVersion` 一致。
  static const String expectedCefVersion =
      '144.0.29+g0b1a012+chromium-144.0.7559.256';

  /// 落地目录名（URL/路径里避免 '+'）。
  static String get _safeVersion => expectedCefVersion.replaceAll('+', '-');

  String? _manifestUrl;

  final StreamController<CefRuntimeState> _controller =
      StreamController<CefRuntimeState>.broadcast();

  CefRuntimeState _state = const CefRuntimeState(CefRuntimeStatus.unknown);

  /// 状态流（broadcast）。供标签栏下载入口 / CEF 占位提示订阅。
  Stream<CefRuntimeState> get stream => _controller.stream;

  /// 当前状态快照。
  CefRuntimeState get state => _state;

  /// 配置 manifest 地址（App 启动早期调用一次）。
  void configure({required String manifestUrl}) {
    _manifestUrl = manifestUrl;
  }

  /// 当前平台-架构标识：windows-x64 / linux-x64 / linux-arm64 / macos-arm64 / macos-x64。
  ///
  /// 用 [Abi.current] 区分架构：
  ///   - Linux：linuxArm64（统信/麒麟等国产 ARM 机）→ linux-arm64，否则 linux-x64；
  ///   - macOS：macosX64（含 Rosetta 下进程）→ macos-x64，否则 macos-arm64。
  static String platformKey() {
    if (Platform.isWindows) return 'windows-x64';
    if (Platform.isLinux) {
      return Abi.current() == Abi.linuxArm64 ? 'linux-arm64' : 'linux-x64';
    }
    if (Platform.isMacOS) {
      return Abi.current() == Abi.macosX64 ? 'macos-x64' : 'macos-arm64';
    }
    throw UnsupportedError('CEF 运行时不支持当前平台');
  }

  /// CEF 运行时基目录（不含版本段）。
  ///
  /// 关键：此公式必须与各端 native 完全一致，使「Dart 下载落地」与「native 加载」
  /// 指向同一目录（Linux 早期 pre_initialize 拿不到 channel 传参，只能各自按相同
  /// 公式从环境变量推导）。对应 native 实现见各端插件的 cef runtime dir 推导。
  ///   - Windows: %LOCALAPPDATA%\cef_webview\cef
  ///   - macOS:   $HOME/Library/Application Support/cef_webview/cef
  ///   - Linux:   $HOME/.local/share/cef_webview/cef
  Directory _baseDir() {
    if (Platform.isWindows) {
      final local = Platform.environment['LOCALAPPDATA'] ??
          '${Platform.environment['USERPROFILE'] ?? r'C:\Users\Default'}\\AppData\\Local';
      return Directory('$local\\cef_webview\\cef');
    }
    final home = Platform.environment['HOME'] ?? '/tmp';
    if (Platform.isMacOS) {
      return Directory('$home/Library/Application Support/cef_webview/cef');
    }
    return Directory('$home/.local/share/cef_webview/cef');
  }

  String _join(String a, String b) => '$a${Platform.pathSeparator}$b';

  Future<bool> _looksLikeRuntimeDir(Directory dir) async {
    if (Platform.isLinux) {
      return await File(_join(dir.path, 'libcef.so')).exists();
    }
    if (Platform.isWindows) {
      return await File(_join(dir.path, 'libcef.dll')).exists();
    }
    if (Platform.isMacOS) {
      return await Directory(_join(
              dir.path, 'Chromium Embedded Framework.framework'))
          .exists();
    }
    return false;
  }

  /// 探测本地是否已就绪；就绪则返回 `cefRoot` 绝对目录，否则返回 null。
  Future<String?> resolveReadyRoot() async {
    try {
      // 显式指定运行期目录（内网 Debug 预装：bootstrap_cef_runtime_linux.sh）。
      final override = Platform.environment['CEF_RUNTIME_ROOT'];
      if (override != null && override.isNotEmpty) {
        final dir = Directory(override);
        if (await _looksLikeRuntimeDir(dir)) {
          _setState(CefRuntimeState(CefRuntimeStatus.ready,
              progress: 1, cefRoot: dir.path));
          return dir.path;
        }
        debugPrint('[CefRuntime] CEF_RUNTIME_ROOT 无效: $override');
      }

      final base = _baseDir();
      final dir = Directory(_join(base.path, _safeVersion));
      final ready = File(_join(dir.path, '.ready'));
      if (await ready.exists() && await _looksLikeRuntimeDir(dir)) {
        _setState(CefRuntimeState(CefRuntimeStatus.ready,
            progress: 1, cefRoot: dir.path));
        return dir.path;
      }
    } catch (e) {
      debugPrint('[CefRuntime] 探测就绪失败: $e');
    }
    if (_state.status == CefRuntimeStatus.unknown) {
      _setState(const CefRuntimeState(CefRuntimeStatus.notInstalled));
    }
    return null;
  }

  /// 若未就绪则下载安装；已就绪直接返回。
  Future<void> ensureReady() async {
    if (await resolveReadyRoot() != null) return;
    await download();
  }

  /// 下载并安装当前平台-架构的 CEF 运行时（供下载入口调用）。
  Future<void> download() async {
    if (_manifestUrl == null) {
      _fail('未配置 manifestUrl，请先调用 CefRuntimeManager.instance.configure(...)');
      return;
    }
    if (_state.status == CefRuntimeStatus.downloading ||
        _state.status == CefRuntimeStatus.extracting ||
        _state.status == CefRuntimeStatus.verifying) {
      return; // 正在进行
    }

    File? tmpPkg;
    Directory? tmpExtract;
    try {
      // 1. 拉取 manifest 并校验版本。
      final manifest = await _fetchJson(Uri.parse(_manifestUrl!));
      final ver = manifest['cefVersion'] as String?;
      if (ver != expectedCefVersion) {
        _fail('服务器 CEF 版本($ver) 与客户端期望($expectedCefVersion) 不一致');
        return;
      }
      final key = platformKey();
      final pkg = (manifest['packages'] as Map?)?[key] as Map?;
      if (pkg == null) {
        _fail('manifest 缺少当前平台包: $key');
        return;
      }
      final pkgUrl = Uri.parse(_manifestUrl!).resolve(pkg['url'] as String);
      final expectSha = (pkg['sha256'] as String?)?.toLowerCase();
      final total = (pkg['size'] as num?)?.toInt() ?? -1;

      final base = _baseDir();
      await base.create(recursive: true);
      final stamp = DateTime.now().millisecondsSinceEpoch;

      // 2. 流式下载到临时文件（更新进度）。
      _setState(CefRuntimeState(CefRuntimeStatus.downloading,
          progress: 0, totalBytes: total > 0 ? total : null));
      tmpPkg = File(_join(base.path, '.download-$stamp.tar.gz'));
      await _downloadTo(pkgUrl, tmpPkg, total);

      // 3. 校验 sha256（流式读，避免一次性载入内存）。
      _setState(const CefRuntimeState(CefRuntimeStatus.verifying, progress: 1));
      final actual = (await sha256.bind(tmpPkg.openRead()).first).toString();
      if (expectSha != null && actual.toLowerCase() != expectSha) {
        _fail('sha256 校验失败：期望 $expectSha 实际 $actual');
        return;
      }

      // 4. 解压到临时目录（系统 tar，保留权限与符号链接，低内存）。
      _setState(const CefRuntimeState(CefRuntimeStatus.extracting, progress: 1));
      tmpExtract = Directory(_join(base.path, '.extract-$stamp'));
      await tmpExtract.create(recursive: true);
      final res =
          await Process.run('tar', ['-xzf', tmpPkg.path, '-C', tmpExtract.path]);
      if (res.exitCode != 0) {
        _fail('解压失败(tar exit=${res.exitCode}): ${res.stderr}');
        return;
      }

      // 5. 安装到版本目录。Windows 上刚解压出的 dll/exe 常被杀毒软件/索引器实时扫描
      //    而短暂占用，导致整目录 rename 报「errno=5 拒绝访问」（C 盘 AppData 尤甚）；
      //    因此这里加退避重试，仍失败则回退到「直接解压到目标目录」绕过整目录 rename。
      final dest = Directory(_join(base.path, _safeVersion));
      await _installRuntime(dest: dest, tmpExtract: tmpExtract, pkg: tmpPkg);
      tmpExtract = null;

      // Linux 子进程兜底补可执行位（tar 一般已保留）。
      if (Platform.isLinux) {
        final sp = File(_join(dest.path, 'cef_webview_subprocess'));
        if (await sp.exists()) {
          try {
            await Process.run('chmod', ['+x', sp.path]);
          } catch (_) {}
        }
      }
      await File(_join(dest.path, '.ready')).writeAsString(expectedCefVersion);

      _setState(CefRuntimeState(CefRuntimeStatus.ready,
          progress: 1, cefRoot: dest.path));
    } catch (e) {
      _fail('下载/安装失败: $e');
    } finally {
      try {
        if (tmpPkg != null && await tmpPkg.exists()) await tmpPkg.delete();
      } catch (_) {}
      try {
        if (tmpExtract != null && await tmpExtract.exists()) {
          await tmpExtract.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  /// 安装解压好的运行时到版本目录 [dest]。
  ///
  /// 快路径：整目录 rename（原子、最快）。Windows 上刚解压的 dll/exe 常被杀软/索引器
  /// 实时扫描而短暂占用，使整目录 rename 报 `errno=5 拒绝访问`；故 rename 先做几次退避
  /// 重试，仍失败则回退到「清空目标目录并把包直接解压进去」——逐个写文件比整目录 rename
  /// 更能容忍占用，且 `.ready` 标记保证半成品不会被 [resolveReadyRoot] 误判为就绪。
  Future<void> _installRuntime({
    required Directory dest,
    required Directory tmpExtract,
    required File pkg,
  }) async {
    await _deleteDirWithRetry(dest);
    try {
      await _renameWithRetry(tmpExtract, dest.path);
      return;
    } catch (e) {
      debugPrint('[CefRuntime] 整目录 rename 失败，回退直接解压到目标目录: $e');
    }
    // 回退：直接解压到目标目录，绕过 Windows 上的整目录 rename 占用问题。
    await _deleteDirWithRetry(dest);
    await dest.create(recursive: true);
    final res = await Process.run('tar', ['-xzf', pkg.path, '-C', dest.path]);
    if (res.exitCode != 0) {
      throw StateError('回退解压失败(tar exit=${res.exitCode}): ${res.stderr}');
    }
  }

  /// 目录 rename 带退避重试（应对 Windows 杀软/占用导致的临时 Access Denied）。
  Future<void> _renameWithRetry(Directory dir, String newPath,
      {int attempts = 5}) async {
    Object? lastErr;
    for (var i = 0; i < attempts; i++) {
      try {
        await dir.rename(newPath);
        return;
      } catch (e) {
        lastErr = e;
        await Future<void>.delayed(Duration(milliseconds: 200 * (i + 1)));
      }
    }
    throw lastErr ?? StateError('rename 失败: $newPath');
  }

  /// 递归删除目录带退避重试（同样应对被占用导致的临时失败）。
  Future<void> _deleteDirWithRetry(Directory dir, {int attempts = 5}) async {
    for (var i = 0; i < attempts; i++) {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
        return;
      } catch (e) {
        if (i == attempts - 1) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 200 * (i + 1)));
      }
    }
  }

  Future<void> _downloadTo(Uri url, File dest, int total) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(url);
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw 'HTTP ${resp.statusCode} for $url';
      }
      final len = total > 0 ? total : resp.contentLength;
      final sink = dest.openWrite();
      int received = 0;
      int lastPermille = -1;
      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        if (len > 0) {
          // 节流：千分比变化才推状态，避免过于频繁。
          final permille = (received * 1000 ~/ len);
          if (permille != lastPermille) {
            lastPermille = permille;
            _setState(CefRuntimeState(CefRuntimeStatus.downloading,
                progress: received / len, totalBytes: len));
          }
        }
      }
      await sink.flush();
      await sink.close();
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _fetchJson(Uri url) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(url);
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw 'HTTP ${resp.statusCode} for $url';
      }
      final body = await resp.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  void _setState(CefRuntimeState s) {
    _state = s;
    if (!_controller.isClosed) _controller.add(s);
  }

  void _fail(String msg) {
    debugPrint('[CefRuntime] $msg');
    _setState(CefRuntimeState(CefRuntimeStatus.error, message: msg));
  }
}
