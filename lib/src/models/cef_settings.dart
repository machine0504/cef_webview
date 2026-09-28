/// 单个浏览器实例的创建参数。
class CefBrowserSettings {
  const CefBrowserSettings({
    this.userAgent,
    this.transparent = false,
    this.enableJavaScript = true,
    this.persistCookies = true,
    this.defaultEncoding = 'UTF-8',
    this.backgroundColor = 0xFFFFFFFF,
    this.windowlessFrameRate,
  });

  /// 自定义 UA，null 时使用 CEF 默认。
  final String? userAgent;

  /// 是否启用透明背景（OSR 下用于圆角/异形叠加）。
  final bool transparent;

  final bool enableJavaScript;

  /// Cookie 是否持久化到磁盘（对应 CEF cache_path 下的持久化存储）。
  final bool persistCookies;

  final String defaultEncoding;

  /// OSR 背景色（ARGB），transparent=true 时忽略。
  final int backgroundColor;

  /// OSR 离屏渲染帧率（fps）。null 表示「跟随显示器刷新率」（由
  /// [CefWebviewController.create] 查询当前显示器刷新率并 clamp 到 30~60 后下发）；
  /// 显式给值则固定使用该帧率。CEF OSR 上限为 60，超出会被 native 侧裁到 60。
  final int? windowlessFrameRate;

  Map<String, dynamic> toMap() => {
        'userAgent': userAgent,
        'transparent': transparent,
        'enableJavaScript': enableJavaScript,
        'persistCookies': persistCookies,
        'defaultEncoding': defaultEncoding,
        'backgroundColor': backgroundColor,
        'windowlessFrameRate': windowlessFrameRate,
      };
}
