import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// 输入事件转换：把 Flutter 的键盘 / 鼠标语义转换为 CEF 需要的
/// Windows Virtual-Key Code 与 `cef_event_flags_t` 修饰符位。
///
/// 这些都是**纯函数 / 纯状态机**，与 Widget 解耦，便于单元测试覆盖每一种
/// 按键、修饰符与点击组合（见 `test/cef_input_test.dart`）。

// --------------------------------------------------------------------------
// CEF 事件标志位（include/internal/cef_types.h: cef_event_flags_t）
// --------------------------------------------------------------------------
const int kEventFlagNone = 0;
const int kEventFlagCapsLockOn = 1 << 0;
const int kEventFlagShiftDown = 1 << 1;
const int kEventFlagControlDown = 1 << 2;
const int kEventFlagAltDown = 1 << 3;
const int kEventFlagLeftMouseButton = 1 << 4;
const int kEventFlagMiddleMouseButton = 1 << 5;
const int kEventFlagRightMouseButton = 1 << 6;

/// macOS Command 键；Windows 下用于 Win/Meta 键。
const int kEventFlagCommandDown = 1 << 7;
const int kEventFlagNumLockOn = 1 << 8;
const int kEventFlagIsKeyPad = 1 << 9;
const int kEventFlagIsLeft = 1 << 10;
const int kEventFlagIsRight = 1 << 11;
const int kEventFlagAltGrDown = 1 << 12;

// --------------------------------------------------------------------------
// CEF 鼠标按钮类型（cef_mouse_button_type_t）：0=left 1=middle 2=right
// --------------------------------------------------------------------------
const int kCefMouseLeft = 0;
const int kCefMouseMiddle = 1;
const int kCefMouseRight = 2;

/// 把 [PointerEvent.buttons] 位域映射为 CEF 鼠标按钮序号。
/// 右键 / 中键优先于左键（同一物理事件通常只有一个主按钮）。
int cefMouseButtonFor(int buttons) {
  if (buttons & kSecondaryMouseButton != 0) return kCefMouseRight;
  if (buttons & kMiddleMouseButton != 0) return kCefMouseMiddle;
  return kCefMouseLeft;
}

/// 根据当前按下的逻辑键、锁定状态与鼠标按钮位域，组合出 CEF 修饰符。
///
/// [pressed] 一般取 `HardwareKeyboard.instance.logicalKeysPressed`；
/// [mouseButtons] 取 `PointerEvent.buttons`，用于让 CEF 在 mouseMove 时
/// 识别「按住拖拽」（框选）。
int cefModifiersFor({
  Set<LogicalKeyboardKey> pressed = const {},
  bool capsLock = false,
  bool numLock = false,
  int mouseButtons = 0,
}) {
  var m = 0;
  if (pressed.contains(LogicalKeyboardKey.shift) ||
      pressed.contains(LogicalKeyboardKey.shiftLeft) ||
      pressed.contains(LogicalKeyboardKey.shiftRight)) {
    m |= kEventFlagShiftDown;
  }
  if (pressed.contains(LogicalKeyboardKey.control) ||
      pressed.contains(LogicalKeyboardKey.controlLeft) ||
      pressed.contains(LogicalKeyboardKey.controlRight)) {
    m |= kEventFlagControlDown;
  }
  if (pressed.contains(LogicalKeyboardKey.alt) ||
      pressed.contains(LogicalKeyboardKey.altLeft) ||
      pressed.contains(LogicalKeyboardKey.altRight)) {
    m |= kEventFlagAltDown;
  }
  if (pressed.contains(LogicalKeyboardKey.meta) ||
      pressed.contains(LogicalKeyboardKey.metaLeft) ||
      pressed.contains(LogicalKeyboardKey.metaRight)) {
    m |= kEventFlagCommandDown;
  }
  if (capsLock) m |= kEventFlagCapsLockOn;
  if (numLock) m |= kEventFlagNumLockOn;
  if (mouseButtons & kPrimaryMouseButton != 0) m |= kEventFlagLeftMouseButton;
  if (mouseButtons & kMiddleMouseButton != 0) m |= kEventFlagMiddleMouseButton;
  if (mouseButtons & kSecondaryMouseButton != 0) {
    m |= kEventFlagRightMouseButton;
  }
  return m;
}

// --------------------------------------------------------------------------
// CEF 指针类型（cef_cursor_type_t，include/internal/cef_types.h）→ Flutter 光标
// --------------------------------------------------------------------------
// OSR 离屏渲染下 CEF 不会自行改系统光标，只会通过 OnCursorChange 回报「此刻该显示
// 哪种指针」（悬停链接=手型、文本=I 形、缩放/拖拽手柄=各向缩放…）。这里把 CEF 的
// 指针枚举值映射为 Flutter 的 [SystemMouseCursor]，交给 widget 的 MouseRegion 应用。
// 纯函数，便于单测覆盖（见 test/cef_input_test.dart）。

/// 将 CEF `cef_cursor_type_t` 整型值映射为 Flutter [MouseCursor]。
/// 未知 / 自定义位图光标（CT_CUSTOM 等）回退为 [SystemMouseCursors.basic]。
MouseCursor cefCursorToFlutter(int cefCursorType) {
  switch (cefCursorType) {
    case 0: // CT_POINTER
      return SystemMouseCursors.basic;
    case 1: // CT_CROSS
      return SystemMouseCursors.precise;
    case 2: // CT_HAND（链接 / 可点击）
      return SystemMouseCursors.click;
    case 3: // CT_IBEAM（可选文本）
      return SystemMouseCursors.text;
    case 4: // CT_WAIT
      return SystemMouseCursors.wait;
    case 5: // CT_HELP
      return SystemMouseCursors.help;
    case 6: // CT_EASTRESIZE
    case 13: // CT_WESTRESIZE
    case 15: // CT_EASTWESTRESIZE
      return SystemMouseCursors.resizeLeftRight;
    case 7: // CT_NORTHRESIZE
    case 10: // CT_SOUTHRESIZE
    case 14: // CT_NORTHSOUTHRESIZE
      return SystemMouseCursors.resizeUpDown;
    case 8: // CT_NORTHEASTRESIZE
      return SystemMouseCursors.resizeUpRight;
    case 9: // CT_NORTHWESTRESIZE
      return SystemMouseCursors.resizeUpLeft;
    case 11: // CT_SOUTHEASTRESIZE
      return SystemMouseCursors.resizeDownRight;
    case 12: // CT_SOUTHWESTRESIZE
      return SystemMouseCursors.resizeDownLeft;
    case 16: // CT_NORTHEASTSOUTHWESTRESIZE
      return SystemMouseCursors.resizeUpRightDownLeft;
    case 17: // CT_NORTHWESTSOUTHEASTRESIZE
      return SystemMouseCursors.resizeUpLeftDownRight;
    case 18: // CT_COLUMNRESIZE
      return SystemMouseCursors.resizeColumn;
    case 19: // CT_ROWRESIZE
      return SystemMouseCursors.resizeRow;
    case 20: // CT_MIDDLEPANNING
    case 21: // CT_EASTPANNING
    case 22: // CT_NORTHPANNING
    case 23: // CT_NORTHEASTPANNING
    case 24: // CT_NORTHWESTPANNING
    case 25: // CT_SOUTHPANNING
    case 26: // CT_SOUTHEASTPANNING
    case 27: // CT_SOUTHWESTPANNING
    case 28: // CT_WESTPANNING
    case 43: // CT_MIDDLE_PANNING_VERTICAL
    case 44: // CT_MIDDLE_PANNING_HORIZONTAL
      return SystemMouseCursors.allScroll;
    case 29: // CT_MOVE
      return SystemMouseCursors.move;
    case 30: // CT_VERTICALTEXT
      return SystemMouseCursors.verticalText;
    case 31: // CT_CELL
      return SystemMouseCursors.cell;
    case 32: // CT_CONTEXTMENU
      return SystemMouseCursors.contextMenu;
    case 33: // CT_ALIAS
      return SystemMouseCursors.alias;
    case 34: // CT_PROGRESS
      return SystemMouseCursors.progress;
    case 35: // CT_NODROP
      return SystemMouseCursors.noDrop;
    case 36: // CT_COPY
    case 48: // CT_DND_COPY
      return SystemMouseCursors.copy;
    case 37: // CT_NONE
      return SystemMouseCursors.none;
    case 38: // CT_NOTALLOWED
    case 46: // CT_DND_NONE
      return SystemMouseCursors.forbidden;
    case 39: // CT_ZOOMIN
      return SystemMouseCursors.zoomIn;
    case 40: // CT_ZOOMOUT
      return SystemMouseCursors.zoomOut;
    case 41: // CT_GRAB
      return SystemMouseCursors.grab;
    case 42: // CT_GRABBING
      return SystemMouseCursors.grabbing;
    case 47: // CT_DND_MOVE
      return SystemMouseCursors.move;
    case 49: // CT_DND_LINK
      return SystemMouseCursors.alias;
    default: // CT_CUSTOM 及未知：无法映射，用默认箭头
      return SystemMouseCursors.basic;
  }
}

/// 数字小键盘上的键（CEF 需要在修饰符里附带 [kEventFlagIsKeyPad]）。
bool isKeypadKey(LogicalKeyboardKey key) => _keypadKeys.contains(key);

final Set<LogicalKeyboardKey> _keypadKeys = {
  LogicalKeyboardKey.numpad0,
  LogicalKeyboardKey.numpad1,
  LogicalKeyboardKey.numpad2,
  LogicalKeyboardKey.numpad3,
  LogicalKeyboardKey.numpad4,
  LogicalKeyboardKey.numpad5,
  LogicalKeyboardKey.numpad6,
  LogicalKeyboardKey.numpad7,
  LogicalKeyboardKey.numpad8,
  LogicalKeyboardKey.numpad9,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.numpadMultiply,
  LogicalKeyboardKey.numpadAdd,
  LogicalKeyboardKey.numpadSubtract,
  LogicalKeyboardKey.numpadDecimal,
  LogicalKeyboardKey.numpadDivide,
  LogicalKeyboardKey.numpadEqual,
};

/// Flutter [LogicalKeyboardKey] → Windows Virtual-Key Code。
///
/// CEF 跨端统一用 VK 作为 `windows_key_code`/`native_key_code`，方向键、
/// 功能键、快捷键据此在网页里正确触发。字母/数字走 ASCII 区间换算，其余
/// 控制键 / 功能键 / OEM 标点走显式映射表。
int windowsKeyCodeFor(LogicalKeyboardKey key) {
  final mapped = _vkMap[key];
  if (mapped != null) return mapped;
  final id = key.keyId;
  // 字母 a-z(0x61-0x7A) -> VK A-Z(0x41-0x5A)
  if (id >= 0x61 && id <= 0x7A) return id - 0x20;
  // 主键盘数字 0-9(0x30-0x39) -> VK 0x30-0x39
  if (id >= 0x30 && id <= 0x39) return id;
  return id & 0xFFFF;
}

final Map<LogicalKeyboardKey, int> _vkMap = {
  // 控制 / 编辑 / 导航
  LogicalKeyboardKey.backspace: 0x08,
  LogicalKeyboardKey.tab: 0x09,
  LogicalKeyboardKey.enter: 0x0D,
  LogicalKeyboardKey.numpadEnter: 0x0D,
  LogicalKeyboardKey.pause: 0x13,
  LogicalKeyboardKey.escape: 0x1B,
  LogicalKeyboardKey.space: 0x20,
  LogicalKeyboardKey.pageUp: 0x21,
  LogicalKeyboardKey.pageDown: 0x22,
  LogicalKeyboardKey.end: 0x23,
  LogicalKeyboardKey.home: 0x24,
  LogicalKeyboardKey.arrowLeft: 0x25,
  LogicalKeyboardKey.arrowUp: 0x26,
  LogicalKeyboardKey.arrowRight: 0x27,
  LogicalKeyboardKey.arrowDown: 0x28,
  LogicalKeyboardKey.printScreen: 0x2C,
  LogicalKeyboardKey.insert: 0x2D,
  LogicalKeyboardKey.delete: 0x2E,

  // 修饰键（区分左右由 native_key_code/flags 体现，VK 用通用值）
  LogicalKeyboardKey.shift: 0x10,
  LogicalKeyboardKey.shiftLeft: 0x10,
  LogicalKeyboardKey.shiftRight: 0x10,
  LogicalKeyboardKey.control: 0x11,
  LogicalKeyboardKey.controlLeft: 0x11,
  LogicalKeyboardKey.controlRight: 0x11,
  LogicalKeyboardKey.alt: 0x12,
  LogicalKeyboardKey.altLeft: 0x12,
  LogicalKeyboardKey.altRight: 0x12,
  LogicalKeyboardKey.capsLock: 0x14,
  LogicalKeyboardKey.numLock: 0x90,
  LogicalKeyboardKey.scrollLock: 0x91,
  LogicalKeyboardKey.metaLeft: 0x5B,
  LogicalKeyboardKey.metaRight: 0x5C,
  LogicalKeyboardKey.contextMenu: 0x5D,

  // 功能键 F1-F12
  LogicalKeyboardKey.f1: 0x70,
  LogicalKeyboardKey.f2: 0x71,
  LogicalKeyboardKey.f3: 0x72,
  LogicalKeyboardKey.f4: 0x73,
  LogicalKeyboardKey.f5: 0x74,
  LogicalKeyboardKey.f6: 0x75,
  LogicalKeyboardKey.f7: 0x76,
  LogicalKeyboardKey.f8: 0x77,
  LogicalKeyboardKey.f9: 0x78,
  LogicalKeyboardKey.f10: 0x79,
  LogicalKeyboardKey.f11: 0x7A,
  LogicalKeyboardKey.f12: 0x7B,

  // 数字小键盘
  LogicalKeyboardKey.numpad0: 0x60,
  LogicalKeyboardKey.numpad1: 0x61,
  LogicalKeyboardKey.numpad2: 0x62,
  LogicalKeyboardKey.numpad3: 0x63,
  LogicalKeyboardKey.numpad4: 0x64,
  LogicalKeyboardKey.numpad5: 0x65,
  LogicalKeyboardKey.numpad6: 0x66,
  LogicalKeyboardKey.numpad7: 0x67,
  LogicalKeyboardKey.numpad8: 0x68,
  LogicalKeyboardKey.numpad9: 0x69,
  LogicalKeyboardKey.numpadMultiply: 0x6A,
  LogicalKeyboardKey.numpadAdd: 0x6B,
  LogicalKeyboardKey.numpadSubtract: 0x6D,
  LogicalKeyboardKey.numpadDecimal: 0x6E,
  LogicalKeyboardKey.numpadDivide: 0x6F,

  // OEM 标点（US 布局）
  LogicalKeyboardKey.semicolon: 0xBA, // ;:
  LogicalKeyboardKey.equal: 0xBB, // =+
  LogicalKeyboardKey.comma: 0xBC, // ,<
  LogicalKeyboardKey.minus: 0xBD, // -_
  LogicalKeyboardKey.period: 0xBE, // .>
  LogicalKeyboardKey.slash: 0xBF, // /?
  LogicalKeyboardKey.backquote: 0xC0, // `~
  LogicalKeyboardKey.bracketLeft: 0xDB, // [{
  LogicalKeyboardKey.backslash: 0xDC, // \|
  LogicalKeyboardKey.bracketRight: 0xDD, // ]}
  LogicalKeyboardKey.quote: 0xDE, // '"
};

/// 双击 / 三击计数状态机。
///
/// 同一按钮、在 [maxIntervalMs] 内、移动不超过 [maxDistance] 像素的连续按下
/// 视为连击：计数在 1→2→3→1 间循环（与浏览器 `detail` 语义一致）。
class ClickCounter {
  ClickCounter({this.maxIntervalMs = 500, this.maxDistance = 4.0});

  /// 两次按下被视为连击的最大间隔（毫秒）。
  final int maxIntervalMs;

  /// 两次按下被视为连击的最大位移（逻辑像素）。
  final double maxDistance;

  int _count = 0;
  int _lastButton = -1;
  int? _lastTimeMs;
  double _lastX = 0;
  double _lastY = 0;

  /// 当前连击数（最近一次 [register] 的返回值）。
  int get count => _count;

  /// 登记一次按下，返回连击数（1=单击，2=双击，3=三击，随后回到 1）。
  /// 测试可注入 [nowMs] 以控制时间。
  int register(int button, double x, double y, {int? nowMs}) {
    final t = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final dx = x - _lastX;
    final dy = y - _lastY;
    final near = dx * dx + dy * dy <= maxDistance * maxDistance;
    final inTime = _lastTimeMs != null && (t - _lastTimeMs!) <= maxIntervalMs;
    if (button == _lastButton && inTime && near) {
      _count = _count >= 3 ? 1 : _count + 1;
    } else {
      _count = 1;
    }
    _lastButton = button;
    _lastTimeMs = t;
    _lastX = x;
    _lastY = y;
    return _count;
  }

  /// 重置状态（如焦点丢失 / 重新进入）。
  void reset() {
    _count = 0;
    _lastButton = -1;
    _lastTimeMs = null;
    _lastX = 0;
    _lastY = 0;
  }
}
