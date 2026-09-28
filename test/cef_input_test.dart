import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cef_webview/src/cef_input.dart';

void main() {
  group('windowsKeyCodeFor', () {
    test('字母 a-z 映射到 VK A-Z', () {
      expect(windowsKeyCodeFor(LogicalKeyboardKey.keyA), 0x41);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.keyM), 0x4D);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.keyZ), 0x5A);
    });

    test('主键盘数字 0-9', () {
      expect(windowsKeyCodeFor(LogicalKeyboardKey.digit0), 0x30);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.digit5), 0x35);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.digit9), 0x39);
    });

    test('功能键 F1-F12', () {
      expect(windowsKeyCodeFor(LogicalKeyboardKey.f1), 0x70);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.f5), 0x74);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.f12), 0x7B);
    });

    test('控制 / 导航 / 编辑键', () {
      expect(windowsKeyCodeFor(LogicalKeyboardKey.enter), 0x0D);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.numpadEnter), 0x0D);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.escape), 0x1B);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.backspace), 0x08);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.tab), 0x09);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.space), 0x20);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.delete), 0x2E);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.insert), 0x2D);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.home), 0x24);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.end), 0x23);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.pageUp), 0x21);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.pageDown), 0x22);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.arrowLeft), 0x25);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.arrowUp), 0x26);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.arrowRight), 0x27);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.arrowDown), 0x28);
    });

    test('数字小键盘数字与运算符', () {
      expect(windowsKeyCodeFor(LogicalKeyboardKey.numpad0), 0x60);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.numpad9), 0x69);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.numpadMultiply), 0x6A);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.numpadAdd), 0x6B);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.numpadSubtract), 0x6D);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.numpadDecimal), 0x6E);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.numpadDivide), 0x6F);
    });

    test('OEM 标点', () {
      expect(windowsKeyCodeFor(LogicalKeyboardKey.semicolon), 0xBA);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.equal), 0xBB);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.comma), 0xBC);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.minus), 0xBD);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.period), 0xBE);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.slash), 0xBF);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.backquote), 0xC0);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.bracketLeft), 0xDB);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.backslash), 0xDC);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.bracketRight), 0xDD);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.quote), 0xDE);
    });

    test('修饰键', () {
      expect(windowsKeyCodeFor(LogicalKeyboardKey.shiftLeft), 0x10);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.controlLeft), 0x11);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.altLeft), 0x12);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.capsLock), 0x14);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.numLock), 0x90);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.metaLeft), 0x5B);
      expect(windowsKeyCodeFor(LogicalKeyboardKey.metaRight), 0x5C);
    });
  });

  group('cefMouseButtonFor', () {
    test('主键 -> 左键 0', () {
      expect(cefMouseButtonFor(kPrimaryMouseButton), kCefMouseLeft);
    });
    test('次键 -> 右键 2', () {
      expect(cefMouseButtonFor(kSecondaryMouseButton), kCefMouseRight);
    });
    test('中键 -> 中键 1', () {
      expect(cefMouseButtonFor(kMiddleMouseButton), kCefMouseMiddle);
    });
    test('无按钮 -> 左键 0', () {
      expect(cefMouseButtonFor(0), kCefMouseLeft);
    });
  });

  group('cefModifiersFor', () {
    test('无修饰', () {
      expect(cefModifiersFor(), 0);
    });

    test('单个修饰键', () {
      expect(cefModifiersFor(pressed: {LogicalKeyboardKey.shiftLeft}),
          kEventFlagShiftDown);
      expect(cefModifiersFor(pressed: {LogicalKeyboardKey.controlRight}),
          kEventFlagControlDown);
      expect(cefModifiersFor(pressed: {LogicalKeyboardKey.altLeft}),
          kEventFlagAltDown);
      expect(cefModifiersFor(pressed: {LogicalKeyboardKey.metaLeft}),
          kEventFlagCommandDown);
    });

    test('组合 Ctrl+Shift', () {
      expect(
        cefModifiersFor(pressed: {
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.shiftLeft,
        }),
        kEventFlagControlDown | kEventFlagShiftDown,
      );
    });

    test('锁定状态', () {
      expect(cefModifiersFor(capsLock: true), kEventFlagCapsLockOn);
      expect(cefModifiersFor(numLock: true), kEventFlagNumLockOn);
    });

    test('鼠标按钮位（拖拽框选）', () {
      expect(cefModifiersFor(mouseButtons: kPrimaryMouseButton),
          kEventFlagLeftMouseButton);
      expect(cefModifiersFor(mouseButtons: kMiddleMouseButton),
          kEventFlagMiddleMouseButton);
      expect(cefModifiersFor(mouseButtons: kSecondaryMouseButton),
          kEventFlagRightMouseButton);
    });
  });

  group('isKeypadKey', () {
    test('小键盘键为真', () {
      expect(isKeypadKey(LogicalKeyboardKey.numpad0), isTrue);
      expect(isKeypadKey(LogicalKeyboardKey.numpad5), isTrue);
      expect(isKeypadKey(LogicalKeyboardKey.numpadEnter), isTrue);
      expect(isKeypadKey(LogicalKeyboardKey.numpadAdd), isTrue);
    });
    test('非小键盘键为假', () {
      expect(isKeypadKey(LogicalKeyboardKey.keyA), isFalse);
      expect(isKeypadKey(LogicalKeyboardKey.enter), isFalse);
      expect(isKeypadKey(LogicalKeyboardKey.digit1), isFalse);
    });
  });

  group('ClickCounter', () {
    test('单击', () {
      final c = ClickCounter();
      expect(c.register(kCefMouseLeft, 10, 10, nowMs: 1000), 1);
    });

    test('双击、三击，再循环回单击', () {
      final c = ClickCounter();
      expect(c.register(kCefMouseLeft, 10, 10, nowMs: 1000), 1);
      expect(c.register(kCefMouseLeft, 10, 10, nowMs: 1100), 2);
      expect(c.register(kCefMouseLeft, 10, 10, nowMs: 1200), 3);
      expect(c.register(kCefMouseLeft, 10, 10, nowMs: 1300), 1);
    });

    test('超时重置为单击', () {
      final c = ClickCounter(maxIntervalMs: 500);
      expect(c.register(kCefMouseLeft, 10, 10, nowMs: 1000), 1);
      expect(c.register(kCefMouseLeft, 10, 10, nowMs: 2000), 1);
    });

    test('位移过大重置为单击', () {
      final c = ClickCounter(maxDistance: 4);
      expect(c.register(kCefMouseLeft, 10, 10, nowMs: 1000), 1);
      expect(c.register(kCefMouseLeft, 100, 100, nowMs: 1050), 1);
    });

    test('换按钮重置为单击', () {
      final c = ClickCounter();
      expect(c.register(kCefMouseLeft, 10, 10, nowMs: 1000), 1);
      expect(c.register(kCefMouseRight, 10, 10, nowMs: 1050), 1);
    });

    test('reset 后重新计数', () {
      final c = ClickCounter();
      c.register(kCefMouseLeft, 10, 10, nowMs: 1000);
      c.register(kCefMouseLeft, 10, 10, nowMs: 1050);
      c.reset();
      expect(c.register(kCefMouseLeft, 10, 10, nowMs: 1100), 1);
    });
  });

  group('cefCursorToFlutter', () {
    test('常用指针类型映射', () {
      expect(cefCursorToFlutter(0), SystemMouseCursors.basic); // CT_POINTER
      expect(cefCursorToFlutter(2), SystemMouseCursors.click); // CT_HAND（链接）
      expect(cefCursorToFlutter(3), SystemMouseCursors.text); // CT_IBEAM
      expect(cefCursorToFlutter(4), SystemMouseCursors.wait); // CT_WAIT
      expect(cefCursorToFlutter(29), SystemMouseCursors.move); // CT_MOVE
      expect(cefCursorToFlutter(38), SystemMouseCursors.forbidden); // NOTALLOWED
    });

    test('缩放手柄映射到双向缩放光标', () {
      expect(cefCursorToFlutter(6), SystemMouseCursors.resizeLeftRight); // EAST
      expect(cefCursorToFlutter(13), SystemMouseCursors.resizeLeftRight); // WEST
      expect(cefCursorToFlutter(7), SystemMouseCursors.resizeUpDown); // NORTH
      expect(cefCursorToFlutter(15),
          SystemMouseCursors.resizeLeftRight); // EASTWEST
      expect(cefCursorToFlutter(14),
          SystemMouseCursors.resizeUpDown); // NORTHSOUTH
      expect(cefCursorToFlutter(18), SystemMouseCursors.resizeColumn); // COLUMN
      expect(cefCursorToFlutter(19), SystemMouseCursors.resizeRow); // ROW
    });

    test('缩放放大/抓取/拖放映射', () {
      expect(cefCursorToFlutter(39), SystemMouseCursors.zoomIn); // ZOOMIN
      expect(cefCursorToFlutter(40), SystemMouseCursors.zoomOut); // ZOOMOUT
      expect(cefCursorToFlutter(41), SystemMouseCursors.grab); // GRAB
      expect(cefCursorToFlutter(42), SystemMouseCursors.grabbing); // GRABBING
      expect(cefCursorToFlutter(48), SystemMouseCursors.copy); // DND_COPY
    });

    test('自定义/未知指针回退为默认箭头', () {
      expect(cefCursorToFlutter(45), SystemMouseCursors.basic); // CT_CUSTOM
      expect(cefCursorToFlutter(9999), SystemMouseCursors.basic); // 越界
      expect(cefCursorToFlutter(-1), SystemMouseCursors.basic);
    });
  });
}
