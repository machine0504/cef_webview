import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'cef_bitmap_view.dart';
import 'cef_input.dart';
import 'cef_webview_controller.dart';

/// 把 OSR 离屏渲染画面通过 `Texture` 显示出来，并将 Flutter 侧的
/// 鼠标 / 滚轮 / 键盘 / IME / 尺寸变化事件转发给 CEF，形成完整交互闭环。
class CefWebviewWidget extends StatefulWidget {
  const CefWebviewWidget({
    super.key,
    required this.controller,
    this.autofocus = true,
    this.placeholder,
    this.enableFileDrop = true,
  });

  final CefWebviewController controller;

  /// 是否在挂载后自动获取键盘焦点。
  final bool autofocus;

  /// 是否启用「拖拽文件到网页」。默认开启：把 OS 拖入的文件转发给 CEF，使网页的
  /// `<input type=file>` / 自定义拖放区收到带正确 name/size/type 的真实 File。
  /// 若某处需要自行接管系统拖放（避免与页面冲突），可置 false。
  final bool enableFileDrop;

  /// 首帧加载完成前覆盖在网页之上的占位（骨架屏 / 纯色 / Logo 等），
  /// 用于避免初始白屏「露馅」。为空则不显示占位。
  final Widget? placeholder;

  @override
  State<CefWebviewWidget> createState() => _CefWebviewWidgetState();
}

class _CefWebviewWidgetState extends State<CefWebviewWidget>
    with SingleTickerProviderStateMixin, DeltaTextInputClient {
  final FocusNode _focusNode = FocusNode(debugLabel: 'CefWebview');

  // 滚轮 / 触摸板惯性滚动：把离散的滚动增量喂进这里，由 Ticker 逐帧指数衰减地
  // 「吐」给 CEF，形成松手后仍滑行一小段再停的浏览器手感（而非原来滑多少滚多少、
  // 到手就停的生硬感）。native 侧对滚动增量做 static_cast<int>，本类内部做残差累计
  // 与取整，避免小于 1px 的尾巴被截断丢步。
  late final _ScrollMomentum _scrollMomentum;
  Size? _lastSize;
  double _lastDpr = 1.0;

  // IME 文本通道：OSR 没有真实输入框，这里把 Flutter 的文本输入（含中文组字/
  // 提交）转发给 CEF；纯按键语义仍由 _onKey 走 rawKeyDown/keyUp。
  TextInputConnection? _textInput;
  TextEditingValue _editingValue = const TextEditingValue();

  // 首帧内容是否就绪（用于淡出加载占位，避免白屏露馅）。
  bool _contentReady = false;

  // 鼠标按钮跟踪：pointerUp 时 PointerEvent.buttons 已为 0，无法判断释放的是
  // 哪个键，必须用按下时记录的按钮；连击数也要在 down/up 间保持一致。
  int _pressedButton = kCefMouseLeft;
  final ClickCounter _clickCounter = ClickCounter();
  int _clickCount = 1;

  // IME 组字光标位置（逻辑像素，相对 webview 左上角），用于把系统输入法候选框
  // 锚定到光标处。初始给一个有效矩形，保证首次组字前几何信息就已下发。
  Rect _caretRect = const Rect.fromLTWH(0, 0, 1, 16);

  // _updateImeGeometry 去抖缓存：仅在尺寸/变换/光标真正变化时才下发文本通道，
  // 避免页面持续重绘时每帧空刷（白白占用平台线程，恢复/高负载时尤甚）。
  Size? _lastImeSize;
  Matrix4? _lastImeTransform;
  Rect? _lastImeCaret;

  bool get _isComposing =>
      _editingValue.composing.isValid && !_editingValue.composing.isCollapsed;

  // CEF 侧当前是否有进行中的组字（预编辑）。组字结束时据此决定「提交上屏」还是
  // 「取消预编辑」，并防止重复提交。随 imeSetComposition 置真、
  // imeCommitText/imeFinishComposing/imeCancelComposition 置假。
  bool _cefComposing = false;

  CefWebviewController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _scrollMomentum = _ScrollMomentum(vsync: this, onScroll: _emitWheel);
    _c.navigation.addListener(_onContentNav);
    _c.onImeCursorRect = _onImeCursorRect;
  }

  // 惯性滚动逐帧回调：把平滑后的整数像素增量下发给 CEF。
  void _emitWheel(Offset position, double dx, double dy, int modifiers) {
    _c.sendMouseWheel(position.dx, position.dy, dx, dy, modifiers: modifiers);
  }

  void _onContentNav() {
    if (_contentReady) return;
    final s = _c.navigation.value;
    // 首次加载完成（progress 到 1，或已有地址且非加载中）即淡出占位。
    if (!s.isLoading && (s.progress >= 1.0 || s.url.isNotEmpty)) {
      setState(() => _contentReady = true);
    }
  }

  @override
  void dispose() {
    _scrollMomentum.dispose();
    _c.navigation.removeListener(_onContentNav);
    if (_c.onImeCursorRect == _onImeCursorRect) _c.onImeCursorRect = null;
    _closeInputConnection();
    _focusNode.dispose();
    super.dispose();
  }

  // ---- IME 连接管理 ----------------------------------------------------

  void _handleFocusChange(bool focused) {
    debugPrint('🅒CEF focusChange=$focused');
    _c.setFocus(focused);
    if (focused) {
      _openInputConnection();
    } else {
      _clickCounter.reset();
      _closeInputConnection();
    }
  }

  void _openInputConnection() {
    if (_textInput != null && _textInput!.attached) {
      _textInput!.show();
      _updateImeGeometry();
      return;
    }
    // 下面这套配置是 Win / Linux / macOS 三端统一的（三端桌面引擎均已实现增量通道，
    // 见各端 embedder 的 enable_delta_model / SendStateUpdateWithDelta）。
    //
    // viewId：Flutter 3.32+ 的 Windows 引擎要求 setClient 必须带 viewId，否则原生侧抛
    // “Could not set client, view ID is null.”，整条文本输入通道失效；其余平台提供它无害
    // 且正确。对齐 Flutter 自带 EditableText 取当前视图 id。
    //
    // enableDeltaModel：让引擎下发“增量”（TextEditingDelta）而非全量 TextEditingValue。
    // OSR 没有真实输入框、文本由 CEF 维护，我们只需把每次「插入/替换/组字/删除」转发给
    // CEF，且全程不 setEditingState 去重置引擎模型——之前用全量通道时为了拿到“单段提交”
    // 而把模型重置为空，会在系统输入法组字途中打断组字区间，导致引擎模型错乱、中文被
    // 成倍重复（如 “你好你好”）。增量模型从根上消除了这种重置。
    //
    // inputType=text（单行）：避免回车被引擎当作插入 "\n" 再多发一条增量，与 _onKey 里
    // 对回车的 rawKeyDown+CHAR 处理重复。回车统一交给 _onKey 转给 CEF，textarea 换行 /
    // 单行表单提交由网页自行决定。
    final config = TextInputConfiguration(
      viewId: View.of(context).viewId,
      inputType: TextInputType.text,
      inputAction: TextInputAction.newline,
      autocorrect: false,
      enableSuggestions: false,
      enableDeltaModel: true,
    );
    debugPrint(
        '🅒CEF openInputConnection(attach) viewId=${View.of(context).viewId}');
    _textInput = TextInput.attach(this, config);
    _textInput!.setEditingState(_editingValue);
    _textInput!.show();
    _updateImeGeometry();
  }

  void _closeInputConnection() {
    _textInput?.close();
    _textInput = null;
    // 失焦/重开连接时，引擎会重建一个空的输入模型；这里把本地镜像同步清空，
    // 保证下次增量的 oldText 与引擎一致（避免 delta.apply 越界）。
    _editingValue = const TextEditingValue();
    _cefComposing = false;
    // 连接关闭后清空去抖缓存，下次获焦重开连接时会重新下发几何。
    _lastImeSize = null;
    _lastImeTransform = null;
    _lastImeCaret = null;
  }

  // 把可编辑区域几何（尺寸 + 变换）与光标矩形下发给引擎。
  //
  // 这是 Windows 端中文输入能用的关键：系统输入法（微软拼音等）需要这些信息
  // 才能进入组字并把候选框/拼音串锚定到光标——否则候选框根本不出现，表现为
  // 「输入法没被激活」。Flutter 自带的 EditableText 也是在焦点打开连接后、并在
  // 每帧维护这些信息（见其 _updateSizeAndTransform / _updateCaretRectIfNeeded）。
  void _updateImeGeometry() {
    final conn = _textInput;
    if (conn == null || !conn.attached) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final size = box.size;
    final transform = box.getTransformTo(null);
    // 去抖：几何与光标都没变就不重复下发（持续重绘时每帧都会进来）。
    if (size == _lastImeSize &&
        transform == _lastImeTransform &&
        _caretRect == _lastImeCaret) {
      return;
    }
    _lastImeSize = size;
    _lastImeTransform = transform;
    _lastImeCaret = _caretRect;
    conn
      ..setEditableSizeAndTransform(size, transform)
      ..setComposingRect(_caretRect)
      ..setCaretRect(_caretRect);
  }

  // CEF 报告的组字光标位置（逻辑像素，相对 webview）→ 系统输入法候选框定位。
  // 注：Linux 下多数输入法（fcitx/搜狗）直接提交、不经 Flutter 组字通道，此回调
  // 通常不触发；Windows 下用它把候选框精确贴到光标处。
  void _onImeCursorRect(int x, int y, int w, int h) {
    _caretRect = Rect.fromLTWH(
      x.toDouble(),
      y.toDouble(),
      (w <= 0 ? 1 : w).toDouble(),
      (h <= 0 ? 16 : h).toDouble(),
    );
    _updateImeGeometry();
  }

  void _syncSize(Size size, double dpr) {
    if (size == _lastSize && dpr == _lastDpr) return;
    _lastSize = size;
    _lastDpr = dpr;
    _c.resize(size.width.round(), size.height.round(), dpr);
  }

  // 当前键盘修饰符（含锁定态）。[mouseButtons] 传入 PointerEvent.buttons，使
  // CEF 在 mouseMove 时能识别「按住拖拽」（框选）。
  int _modifiers({int mouseButtons = 0}) {
    final hw = HardwareKeyboard.instance;
    final locks = hw.lockModesEnabled;
    return cefModifiersFor(
      pressed: hw.logicalKeysPressed,
      capsLock: locks.contains(KeyboardLockMode.capsLock),
      numLock: locks.contains(KeyboardLockMode.numLock),
      mouseButtons: mouseButtons,
    );
  }

  // 功能/导航键（不产生文本）：转发后拦截，避免触发 Flutter 默认行为（如 Tab 移焦点）。
  static final Set<LogicalKeyboardKey> _functionalKeys = {
    LogicalKeyboardKey.backspace,
    LogicalKeyboardKey.delete,
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.home,
    LogicalKeyboardKey.end,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
    LogicalKeyboardKey.insert,
  };

  // 转发按键语义（rawKeyDown/keyUp）让网页 keydown/keyup、方向键、快捷键生效；
  // 「可见字符 / 空格」放行（return ignored），让它们经文本输入「增量」通道
  // （updateEditingValueWithDeltas → imeCommitText）打入 CEF——否则会重复插入。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // 组字进行中：按键由系统输入法消费（Flutter 通常不会再投递为 KeyEvent），
    // 即便投递也不转发，避免干扰/重复正在进行的组字。
    if (_isComposing) return KeyEventResult.ignored;

    final logical = event.logicalKey;
    final win = windowsKeyCodeFor(logical);
    debugPrint('🅒CEF key ${event.runtimeType} "${logical.keyLabel}" '
        'vk=0x${win.toRadixString(16)}');
    var mods = _modifiers();
    if (isKeypadKey(logical)) mods |= kEventFlagIsKeyPad;
    final isEnter = logical == LogicalKeyboardKey.enter ||
        logical == LogicalKeyboardKey.numpadEnter;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _c.sendKey(
        type: 0,
        windowsKeyCode: win,
        nativeKeyCode: win,
        modifiers: mods,
      );
      // 回车换行字符不会经文本通道产出，这里补一个 char(\r)，使 textarea 能换行、
      // 单行表单能提交。可见字符/空格不在此发：统一走文本输入「增量」通道
      // （updateEditingValueWithDeltas → imeCommitText），否则会与之重复插入。
      if (isEnter) {
        _c.sendKey(
          type: 2,
          windowsKeyCode: 0x0D,
          nativeKeyCode: 0x0D,
          character: 0x0D,
          modifiers: mods,
        );
      }
    } else if (event is KeyUpEvent) {
      _c.sendKey(
        type: 1,
        windowsKeyCode: win,
        nativeKeyCode: win,
        modifiers: mods,
      );
    }
    final hw = HardwareKeyboard.instance;
    final isShortcut =
        hw.isControlPressed || hw.isAltPressed || hw.isMetaPressed;
    if (isEnter || _functionalKeys.contains(logical) || isShortcut) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _handlePointerDown(PointerDownEvent e) {
    // 点击即刹车：滑行途中按下鼠标应立即停住（与浏览器一致）。
    _scrollMomentum.stop();
    final button = cefMouseButtonFor(e.buttons);
    _pressedButton = button;
    _clickCount =
        _clickCounter.register(button, e.localPosition.dx, e.localPosition.dy);
    // 把组字光标种子设到点击处，确保首次组字候选框出现在点击位置附近，
    // 之后由 _onImeCursorRect 精修到真实光标。
    _caretRect = Rect.fromLTWH(e.localPosition.dx, e.localPosition.dy, 1, 16);
    final wasFocused = _focusNode.hasFocus;
    debugPrint('🅒CEF pointerDown btn=$button wasFocused=$wasFocused');
    _focusNode.requestFocus();
    // autofocus 已持有焦点时 onFocusChange 不会再触发，这里主动确保 IME 连接
    // 打开并刷新几何，否则点进网页输入框却唤不起输入法。
    if (wasFocused) _openInputConnection();
    _c.sendMouseButton(
      e.localPosition.dx,
      e.localPosition.dy,
      button: button,
      down: true,
      clickCount: _clickCount,
      modifiers: _modifiers(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final Widget core = LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _syncSize(size, dpr);
          // 维持引擎侧的可编辑几何信息（布局/滚动变化后候选框仍跟随光标）。
          if (_focusNode.hasFocus) _updateImeGeometry();
        });

        return Focus(
          focusNode: _focusNode,
          autofocus: widget.autofocus,
          onKeyEvent: _onKey,
          onFocusChange: _handleFocusChange,
          child: Listener(
            onPointerDown: _handlePointerDown,
            onPointerUp: (e) => _c.sendMouseButton(
              e.localPosition.dx,
              e.localPosition.dy,
              button: _pressedButton,
              down: false,
              clickCount: _clickCount,
              modifiers: _modifiers(),
            ),
            onPointerMove: (e) => _c.sendMouseMove(
              e.localPosition.dx,
              e.localPosition.dy,
              modifiers: _modifiers(mouseButtons: e.buttons),
            ),
            onPointerHover: (e) => _c.sendMouseMove(
              e.localPosition.dx,
              e.localPosition.dy,
              modifiers: _modifiers(mouseButtons: e.buttons),
            ),
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) {
                // 鼠标滚轮：Flutter 的 PointerScrollEvent.scrollDelta（向下滚动为正）
                // 与触摸板 PointerPanZoomUpdateEvent.panDelta（见下）符号相反，需取负
                // 才能与 CEF/触摸板方向一致——否则鼠标滚轮上下相反。
                final mods = _modifiers();
                // Ctrl/⌘+滚轮=网页缩放：不加惯性，直接下发，否则松手后会继续「漂移缩放」。
                final hw = HardwareKeyboard.instance;
                if (hw.isControlPressed || hw.isMetaPressed) {
                  _c.sendMouseWheel(e.localPosition.dx, e.localPosition.dy,
                      -e.scrollDelta.dx, -e.scrollDelta.dy,
                      modifiers: mods);
                } else {
                  _scrollMomentum.add(e.localPosition, -e.scrollDelta.dx,
                      -e.scrollDelta.dy, mods);
                }
              } else if (e is PointerScrollInertiaCancelEvent) {
                // 系统告知惯性被用户触碰打断：立即停住滑行。
                _scrollMomentum.stop();
              }
            },
            // 笔记本触摸板双指滚动在桌面平台以 PanZoom 手势序列下发，
            // 这里把每次 pan 增量喂进惯性滚动器，转成滚轮事件平滑转发给 CEF。
            onPointerPanZoomStart: (e) {
              _focusNode.requestFocus();
              // 新手势开始，先清掉上一段尚未滑完的拖尾，避免方向叠加打架。
              _scrollMomentum.stop();
            },
            onPointerPanZoomUpdate: (e) {
              // 触摸板双指滚动：panDelta 与鼠标 scrollDelta 符号相反、已与 CEF 同向，
              // 因此这里不取负（取负反而会让触摸板上下颠倒）。
              _scrollMomentum.add(
                  e.localPosition, e.panDelta.dx, e.panDelta.dy, _modifiers());
            },
            // 光标随网页悬停元素变化：由 controller.cursor（原生 onCursorChange
            // 驱动）决定 MouseRegion 显示哪种指针（链接=手型 / 文本=I 形 / 缩放等）。
            child: ValueListenableBuilder<MouseCursor>(
              valueListenable: _c.cursor,
              builder: (context, cursor, child) => MouseRegion(
                onExit: (e) => _c.sendMouseMove(
                    e.localPosition.dx, e.localPosition.dy,
                    leave: true),
                cursor: cursor,
                child: child,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 软件渲染器下外部纹理在 embedder 层不可用（Texture 只会一片空白），
                  // 改由 CefBitmapView 经 FFI 拉 BGRA 位图、转 ui.Image 显示。
                  // 走哪条路由 native 在 createBrowser 时告知，不在 Dart 侧猜。
                  if (_c.bitmapMode)
                    CefBitmapView(
                      slotId: _c.textureId,
                      filterQuality: FilterQuality.low,
                    )
                  else
                    Texture(
                      textureId: _c.textureId,
                      // OSR 缓冲是设备像素（logical×dpr），在逻辑尺寸里显示相当于降采样；
                      // medium(三线性) 每帧 GPU 采样开销偏大，low(双线性) 对 2:1 降采样
                      // 质量足够且更省，复杂页面掉帧时更稳。
                      filterQuality: FilterQuality.low,
                    ),
                  if (widget.placeholder != null)
                    IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _contentReady ? 0.0 : 1.0,
                        duration: const Duration(milliseconds: 250),
                        child: widget.placeholder,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );

    // 拖拽上传：用 DropTarget 接住 OS 拖入的文件，转发给 CEF 的 DragTarget 时序。
    // desktop_drop 的 localPosition 已是「相对本控件的逻辑像素」（内部 globalToLocal
    // 且已处理 Windows DPR），与鼠标事件同一坐标空间，直接透传给 CEF 即可。
    if (!widget.enableFileDrop) return core;
    return DropTarget(
      onDragDone: _handleFileDrop,
      child: core,
    );
  }

  // 把 OS 拖入的文件按 CEF OSR 拖拽时序注入：enter(带文件数据)→over→drop。
  // desktop_drop 仅在「落下」时给出文件路径，故三步在此一次性完成（CEF 的
  // DragTargetDrop 不再携带数据，数据必须在 DragTargetDragEnter 时给出）。
  //
  // 三步之间必须留出间隔。enter/over/drop 都是异步 IPC 到渲染进程，页面只有在
  // dragover 里 preventDefault 之后 Blink 才认为这次拖放被接受、才会把 drop 派发
  // 给页面。背靠背发三条时，靠 dragover 节流/状态位判断拖放的上传组件
  // （Element Plus、Ant Design 的拖拽上传区都是这类）来不及置位，drop 被直接丢掉，
  // 表现为「拖进去没任何反应」。发两次 over 且坐标略有变化，是为了绕开按
  // 「坐标未变即重复事件」过滤的实现。
  Future<void> _handleFileDrop(DropDoneDetails details) async {
    // 只转发磁盘上真实存在的文件。desktop_drop 在 Linux 上把落下来的数据按行当路径
    // 回传，`Uri.tryParse` 解不出 file scheme 时会原样返回那行文本——拖拽协商到
    // STRING/纯文本目标时，拿到的就不是路径。目录同样剔除：CEF 上传不了目录。
    final paths = <String>[
      for (final f in details.files)
        if (f.path.isNotEmpty && File(f.path).existsSync()) f.path,
    ];
    if (paths.isEmpty) return;
    final Offset pos = details.localPosition;
    final int mods = _modifiers();
    const Duration settle = Duration(milliseconds: 16);
    await _c.dragTargetDragEnter(pos.dx, pos.dy, paths: paths, modifiers: mods);
    await Future<void>.delayed(settle);
    await _c.dragTargetDragOver(pos.dx, math.max(0, pos.dy - 1),
        modifiers: mods);
    await Future<void>.delayed(settle);
    await _c.dragTargetDragOver(pos.dx, pos.dy, modifiers: mods);
    await Future<void>.delayed(settle);
    await _c.dragTargetDrop(pos.dx, pos.dy, modifiers: mods);
  }

  // ---- TextInputClient（IME 文本通道）---------------------------------

  @override
  TextEditingValue? get currentTextEditingValue => _editingValue;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    // 三端桌面引擎都已开启增量模型（enableDeltaModel），文本变更一律走
    // updateEditingValueWithDeltas；此全量回调正常不会触发，仅作兜底：同步本地镜像，
    // 以防个别平台/场景回退到全量通道时本地状态与引擎脱节。
    _editingValue = value;
  }

  // 增量文本输入（三端统一正路）：把系统输入法/键盘对文本的每一次变更——插入、替换、
  // 组字、删除——翻译成对应的 CEF IME 调用。OSR 下文本由 CEF 维护，这里只转发“变化”，
  // 不回写/重置引擎模型，从根上避免“组字途中被重置”导致的中文重复。
  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> deltas) {
    for (final delta in deltas) {
      _editingValue = delta.apply(_editingValue);
      final composing = _editingValue.composing;
      final composingNow = composing.isValid && !composing.isCollapsed;
      debugPrint('🅒CEF delta ${delta.runtimeType} '
          'text="${_editingValue.text}" composing=$composing');

      if (composingNow) {
        // 组字中：把当前组字串作为预编辑下发给 CEF，候选框跟随光标。
        final text = composing.textInside(_editingValue.text);
        _c.imeSetComposition(text,
            selectionStart: text.length, selectionEnd: text.length);
        _cefComposing = true;
        _updateImeGeometry();
        continue;
      }

      // 本次增量之后不再处于组字态：
      if (delta is TextEditingDeltaInsertion) {
        // 普通插入（英文/标点/直接提交的输入法）→ 提交上屏。
        if (delta.textInserted.isNotEmpty) {
          _c.imeCommitText(delta.textInserted);
        }
        _cefComposing = false;
      } else if (delta is TextEditingDeltaReplacement) {
        // 组字结果整体替换并提交（多数输入法选词/按空格后走此路径）。
        _c.imeCommitText(delta.replacementText);
        _cefComposing = false;
      } else if (delta is TextEditingDeltaNonTextUpdate) {
        // 文本未变、组字区间结束 → 把 CEF 中正在进行的预编辑提交上屏。
        if (_cefComposing) {
          _c.imeFinishComposing();
          _cefComposing = false;
        }
      } else if (delta is TextEditingDeltaDeletion) {
        // 组字被取消（预编辑清空）→ 取消 CEF 预编辑；非组字态的退格由 _onKey 的
        // VK_BACK 处理，这里不重复删字。
        if (_cefComposing) {
          _c.imeCancelComposition();
          _cefComposing = false;
        }
      }
    }
  }

  @override
  void performAction(TextInputAction action) {
    // 回车等动作已由 _onKey 的 rawKeyDown(Enter) 处理，这里无需重复。
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}

  @override
  void didChangeInputControl(
      TextInputControl? oldControl, TextInputControl? newControl) {}

  @override
  void performSelector(String selectorName) {}

  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  void connectionClosed() {
    _textInput = null;
  }
}

/// 惯性 / 平滑滚动器：把离散的滚轮 / 触摸板增量累积成「目标位移」，再由 Ticker
/// 逐帧按指数衰减地下发给 CEF，形成「滑一段再缓缓停」的浏览器手感。
///
/// 设计要点：
///  - 指数衰减（时间常数 [_tauMs]）而非固定步长：掉帧时按真实帧长补偿，快慢一致；
///    总位移量保持不变（滑多少最终仍滚多少），只是把「瞬间到位」摊到几百毫秒里滑完。
///  - 残差累计（[_residualX]/[_residualY]）：CEF 的 SendMouseWheelEvent 增量是整型，
///    逐帧吐出的小数若直接下发会被 static_cast<int> 截断，导致尾段「越滚越慢却永不停」
///    甚至小增量整帧丢失（触摸板惯性尾巴发虚的元凶之一）。这里只下发整数像素、把不足
///    1px 的部分留到下一帧。
///  - 连续输入自动累加：同方向连滚会叠加目标、反向会抵消，天然顺滑。
class _ScrollMomentum {
  _ScrollMomentum({
    required TickerProvider vsync,
    required this.onScroll,
  }) {
    _ticker = vsync.createTicker(_onTick);
  }

  /// 逐帧下发平滑后的整数像素增量：`onScroll(位置, dx, dy, 修饰键)`。
  final void Function(Offset position, double dx, double dy, int modifiers)
      onScroll;

  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  // 尚未吐给 CEF 的目标位移（逻辑像素）。
  double _pendingX = 0;
  double _pendingY = 0;
  // 不足 1px 的残差，累计到下一帧，避免整型截断丢步。
  double _residualX = 0;
  double _residualY = 0;
  Offset _position = Offset.zero;
  int _modifiers = 0;

  // 平滑时间常数（ms）：越大拖尾越长越顺、越小越跟手。
  static const double _tauMs = 70;
  // 目标位移两轴都小于该阈值（px）即收尾停表。
  static const double _epsilon = 0.6;

  /// 累加一段滚动增量并（按需）启动滑行。
  void add(Offset position, double dx, double dy, int modifiers) {
    if (dx == 0 && dy == 0) return;
    _position = position;
    _modifiers = modifiers;
    _pendingX += dx;
    _pendingY += dy;
    if (!_ticker.isActive) {
      _lastElapsed = Duration.zero;
      _ticker.start();
    }
  }

  /// 立即停住并清空所有待滑位移（点击 / 新手势 / 惯性取消时调用）。
  void stop() {
    _pendingX = 0;
    _pendingY = 0;
    _residualX = 0;
    _residualY = 0;
    _lastElapsed = Duration.zero;
    if (_ticker.isActive) _ticker.stop();
  }

  void _onTick(Duration elapsed) {
    final double dtMs = _lastElapsed == Duration.zero
        ? 16.0
        : (elapsed - _lastElapsed).inMicroseconds / 1000.0;
    _lastElapsed = elapsed;

    // 本帧吐出目标位移的一部分（比例随帧长变化，掉帧也稳定）。
    final double k = 1 - math.exp(-dtMs / _tauMs);
    final double stepX = _pendingX * k;
    final double stepY = _pendingY * k;
    _pendingX -= stepX;
    _pendingY -= stepY;

    // 残差累计后仅下发整数像素，避免 <1px 被原生截断。
    _residualX += stepX;
    _residualY += stepY;
    final double outX = _residualX.truncateToDouble();
    final double outY = _residualY.truncateToDouble();
    _residualX -= outX;
    _residualY -= outY;
    if (outX != 0 || outY != 0) onScroll(_position, outX, outY, _modifiers);

    // 收尾：目标已足够小，把剩余（含残差）一次性取整吐掉再停表。
    if (_pendingX.abs() < _epsilon && _pendingY.abs() < _epsilon) {
      final double tailX = (_pendingX + _residualX).roundToDouble();
      final double tailY = (_pendingY + _residualY).roundToDouble();
      if (tailX != 0 || tailY != 0) {
        onScroll(_position, tailX, tailY, _modifiers);
      }
      stop();
    }
  }

  void dispose() {
    _ticker.dispose();
  }
}
