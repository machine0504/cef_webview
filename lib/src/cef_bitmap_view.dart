import 'dart:ffi';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Flutter **软件渲染器**（`FLUTTER_LINUX_RENDERER=software`）下的 CEF 画面显示。
///
/// 为什么需要它：Flutter Linux 的外部纹理（`FlTextureGL` / `FlPixelBufferTexture`）在
/// embedder 层都经由 GL 实现——后者只是替调用方做 CPU→GL 上传。软件渲染器不创建 GL
/// 上下文，外部纹理整体失效（引擎日志 `external texture support is not enabled`），
/// `Texture` widget 只会显示一片空白。
///
/// 这里改走另一条路：native 侧把 CEF OnPaint 的 BGRA 位图存进「位图槽」，本控件经
/// FFI 拉取，用 [ui.decodeImageFromPixels] 生成 [ui.Image] 交给 [RawImage] 显示。
/// `ui.Image` 是 Skia 内部图像，软件渲染器下走 Skia 的 CPU 后端，完全支持。
///
/// 取帧节奏跟随 [Ticker]（与 Flutter 帧同步），靠帧序号判断有无新内容：CEF 的 OnPaint
/// 只在页面真正变化时触发，静态页面下序号不变，这里就什么都不做，开销接近零。

// ---- FFI 绑定 ----------------------------------------------------------
// 插件 .so 已随 app 加载，用 DynamicLibrary.process() 即可解析符号。
// 接口刻意不带 out 参数，因此这里无需分配任何 native 内存（不依赖 package:ffi）。

typedef _SeqNative = Int64 Function(Int64);
typedef _SeqDart = int Function(int);
typedef _AcquireNative = Pointer<Uint8> Function(Int64);
typedef _AcquireDart = Pointer<Uint8> Function(int);
typedef _SizeNative = Int64 Function(Int64);
typedef _SizeDart = int Function(int);

class _CefBitmapFfi {
  _CefBitmapFfi._(this.seq, this.acquire, this.size);

  final _SeqDart seq;
  final _AcquireDart acquire;
  final _SizeDart size;

  static _CefBitmapFfi? _instance;
  static bool _tried = false;

  /// 解析失败返回 null（例如非 Linux、或插件未加载）。调用方据此回退到占位显示。
  static _CefBitmapFfi? get instance {
    if (_tried) return _instance;
    _tried = true;
    try {
      final lib = DynamicLibrary.process();
      _instance = _CefBitmapFfi._(
        lib.lookupFunction<_SeqNative, _SeqDart>('cefwv_bitmap_seq'),
        lib.lookupFunction<_AcquireNative, _AcquireDart>('cefwv_bitmap_acquire'),
        lib.lookupFunction<_SizeNative, _SizeDart>('cefwv_bitmap_snapshot_size'),
      );
    } catch (e) {
      debugPrint('[cef_webview] 位图 FFI 符号解析失败，网页将无法显示: $e');
      _instance = null;
    }
    return _instance;
  }
}

/// 以 [slotId] 标识的 CEF 位图槽为源，持续拉帧并显示。
class CefBitmapView extends StatefulWidget {
  const CefBitmapView({
    super.key,
    required this.slotId,
    this.filterQuality = FilterQuality.low,
  });

  /// native 侧位图槽编号（`createBrowser` 在 bitmapMode 下返回的 textureId）。
  final int slotId;

  final FilterQuality filterQuality;

  @override
  State<CefBitmapView> createState() => _CefBitmapViewState();
}

class _CefBitmapViewState extends State<CefBitmapView>
    with SingleTickerProviderStateMixin {
  ui.Image? _image;
  Ticker? _ticker;
  int _lastSeq = 0;
  // 解码是异步的，未完成时不再发起新的，否则高频页面会堆积任务把 UI 线程压垮。
  bool _decoding = false;

  @override
  void initState() {
    super.initState();
    if (_CefBitmapFfi.instance != null) {
      _ticker = createTicker(_onTick)..start();
    }
  }

  @override
  void didUpdateWidget(CefBitmapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.slotId != widget.slotId) {
      _lastSeq = 0; // 换了浏览器实例，强制重新取帧
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  void _onTick(Duration _) {
    if (_decoding) return;
    final ffi = _CefBitmapFfi.instance;
    if (ffi == null) return;

    final seq = ffi.seq(widget.slotId);
    if (seq == 0 || seq == _lastSeq) return; // 无帧或内容未变，静态页面走这里

    final ptr = ffi.acquire(widget.slotId);
    if (ptr == nullptr) return;
    // 尺寸必须取「快照的」而非当前帧的：两次调用之间 CEF 可能因窗口缩放换了分辨率，
    // 用错尺寸解释像素会花屏甚至越界。
    final packed = ffi.size(widget.slotId);
    final w = (packed >> 32) & 0xFFFFFFFF;
    final h = packed & 0xFFFFFFFF;
    if (w <= 0 || h <= 0) return;

    // 必须拷进 Dart 堆再解码：decodeImageFromPixels 是异步的，而 native 快照会在
    // 下一次 acquire 时被覆写，直接把视图交出去可能解出撕裂帧。
    final bytes = Uint8List.fromList(ptr.asTypedList(w * h * 4));

    _lastSeq = seq;
    _decoding = true;
    // BGRA 直传，不做逐像素转色——CEF OSR 输出就是 BGRA8888。
    ui.decodeImageFromPixels(bytes, w, h, ui.PixelFormat.bgra8888, (img) {
      _decoding = false;
      if (!mounted) {
        img.dispose();
        return;
      }
      final old = _image;
      setState(() => _image = img);
      old?.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img == null) return const SizedBox.expand();
    return RawImage(
      image: img,
      fit: BoxFit.fill,
      filterQuality: widget.filterQuality,
    );
  }
}
