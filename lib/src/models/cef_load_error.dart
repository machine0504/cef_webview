/// 页面加载失败信息，对应 CEF CefLoadHandler::OnLoadError。
class CefLoadError {
  const CefLoadError({
    required this.errorCode,
    required this.errorText,
    required this.failedUrl,
  });

  /// CEF cef_errorcode_t（负数），例如 -105 = ERR_NAME_NOT_RESOLVED。
  final int errorCode;
  final String errorText;
  final String failedUrl;

  factory CefLoadError.fromMap(Map<dynamic, dynamic> map) => CefLoadError(
        errorCode: (map['errorCode'] as num?)?.toInt() ?? 0,
        errorText: map['errorText'] as String? ?? 'Unknown error',
        failedUrl: map['failedUrl'] as String? ?? '',
      );

  /// 是否为可忽略的“非真实失败”（被主动中止 / 仍在加载）。
  bool get isAborted => errorCode == -3; // ERR_ABORTED

  @override
  String toString() =>
      'CefLoadError($errorCode: $errorText, url: $failedUrl)';
}
