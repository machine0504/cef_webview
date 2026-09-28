/// 浏览器导航/加载状态快照，由原生侧的 OnLoadingStateChange /
/// OnAddressChange / OnTitleChange 等回调聚合而成。
class CefNavigationState {
  const CefNavigationState({
    this.url = '',
    this.title = '',
    this.isLoading = false,
    this.canGoBack = false,
    this.canGoForward = false,
    this.progress = 0.0,
  });

  final String url;
  final String title;
  final bool isLoading;
  final bool canGoBack;
  final bool canGoForward;

  /// 0.0 ~ 1.0 估算加载进度。
  final double progress;

  CefNavigationState copyWith({
    String? url,
    String? title,
    bool? isLoading,
    bool? canGoBack,
    bool? canGoForward,
    double? progress,
  }) {
    return CefNavigationState(
      url: url ?? this.url,
      title: title ?? this.title,
      isLoading: isLoading ?? this.isLoading,
      canGoBack: canGoBack ?? this.canGoBack,
      canGoForward: canGoForward ?? this.canGoForward,
      progress: progress ?? this.progress,
    );
  }

  @override
  String toString() =>
      'CefNavigationState(url: $url, title: $title, loading: $isLoading, '
      'back: $canGoBack, forward: $canGoForward, progress: $progress)';
}
