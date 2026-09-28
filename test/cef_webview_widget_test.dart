import 'package:cef_webview/cef_webview.dart';
import 'package:cef_webview/src/cef_input.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证 CefWebviewWidget 把 Flutter 的鼠标 / 键盘 / IME / 焦点事件正确转换为
/// 平台通道调用（用 mock handler 捕获 cef_webview 通道的全部 invoke）。
///
/// IME 走 Flutter「增量模型」（enableDeltaModel + DeltaTextInputClient），三端
/// （Win/Linux/macOS）统一。测试用 `tester.testTextInput` 校验出站配置/几何，并直接向
/// 文本输入通道回灌 TextInputClient.updateEditingStateWithDeltas 模拟系统输入法的组字/提交。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  Map asMap(MethodCall c) => c.arguments as Map;
  List<MethodCall> only(String method) =>
      calls.where((c) => c.method == method).toList();

  // 模拟引擎把一组增量回灌给框架 → 路由到当前连接的 updateEditingValueWithDeltas。
  // 框架按「当前输入连接」分发，这里 client id 用 -1 即可命中。
  Future<void> sendDeltas(List<Map<String, dynamic>> deltas) {
    return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(
        MethodCall('TextInputClient.updateEditingStateWithDeltas', <dynamic>[
          -1,
          <String, dynamic>{'deltas': deltas},
        ]),
      ),
      (_) {},
    );
  }

  // 构造一条增量 JSON（字段与各端 embedder 下发格式一致）。
  Map<String, dynamic> delta({
    required String oldText,
    required String deltaText,
    required int deltaStart,
    required int deltaEnd,
    required int selection,
    required int composingBase,
    required int composingExtent,
  }) =>
      <String, dynamic>{
        'oldText': oldText,
        'deltaText': deltaText,
        'deltaStart': deltaStart,
        'deltaEnd': deltaEnd,
        'selectionBase': selection,
        'selectionExtent': selection,
        'selectionAffinity': 'TextAffinity.downstream',
        'selectionIsDirectional': false,
        'composingBase': composingBase,
        'composingExtent': composingExtent,
      };

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CefWebview.channel, (call) async {
      calls.add(call);
      if (call.method == 'createBrowser') {
        return <String, Object?>{'browserId': 1, 'textureId': 1};
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CefWebview.channel, null);
  });

  Future<CefWebviewController> pump(WidgetTester tester) async {
    final controller = CefWebviewController.forTest(browserId: 1, textureId: 1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: CefWebviewWidget(controller: controller),
            ),
          ),
        ),
      ),
    );
    await tester.pump(); // 处理 autofocus 的 post-frame
    await tester.pump(); // 让 FocusManager 真正应用焦点并触发 onFocusChange
    return controller;
  }

  Offset center(WidgetTester tester) =>
      tester.getCenter(find.byType(CefWebviewWidget));

  testWidgets('挂载即上报 setFocus(true)，并以 viewId+增量模型打开 IME 连接（含可编辑几何）',
      (tester) async {
    await pump(tester);

    final focusCalls = only('setFocus');
    expect(focusCalls, isNotEmpty);
    expect(asMap(focusCalls.last)['focused'], true);

    // setClient 必须带 viewId（Win 引擎硬性要求，否则整条文本通道失效）并开启增量模型。
    final args = tester.testTextInput.setClientArgs;
    expect(args, isNotNull);
    expect(args!['viewId'], isNotNull);
    expect(args['enableDeltaModel'], true);

    // 焦点打开连接后应立刻下发可编辑几何（输入法激活/候选框定位的关键）。
    final imeLog = tester.testTextInput.log.map((c) => c.method);
    expect(imeLog, contains('TextInput.setEditableSizeAndTransform'));
    expect(imeLog, contains('TextInput.setCaretRect'));
  });

  testWidgets('左键点击：mouseButton 按下+抬起，button=左，clickCount=1',
      (tester) async {
    await pump(tester);
    calls.clear();

    await tester.tapAt(center(tester));
    await tester.pump();

    final btn = only('mouseButton');
    expect(btn.length, 2);
    final down = btn.firstWhere((c) => asMap(c)['down'] == true);
    final up = btn.firstWhere((c) => asMap(c)['down'] == false);
    expect(asMap(down)['button'], kCefMouseLeft);
    expect(asMap(down)['clickCount'], 1);
    expect(asMap(up)['button'], kCefMouseLeft);
  });

  testWidgets('右键点击：按下与抬起的 button 都为右键（修复抬起误判为左键）',
      (tester) async {
    await pump(tester);
    calls.clear();

    final g = await tester.startGesture(center(tester),
        kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await tester.pump();
    await g.up();
    await tester.pump();

    final btn = only('mouseButton');
    expect(btn.length, 2);
    for (final c in btn) {
      expect(asMap(c)['button'], kCefMouseRight);
    }
  });

  testWidgets('双击：第二次按下 clickCount=2', (tester) async {
    await pump(tester);
    calls.clear();

    final p = center(tester);
    await tester.tapAt(p);
    await tester.tapAt(p); // 紧接着第二击（真实时钟间隔 < 500ms）
    await tester.pump();

    final downs = only('mouseButton')
        .where((c) => asMap(c)['down'] == true)
        .toList();
    expect(downs.length, 2);
    expect(asMap(downs[0])['clickCount'], 1);
    expect(asMap(downs[1])['clickCount'], 2);
  });

  testWidgets('按住左键拖拽：mouseMove 携带左键修饰符（框选）', (tester) async {
    await pump(tester);
    calls.clear();

    final g = await tester.startGesture(center(tester),
        kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await g.moveBy(const Offset(30, 0));
    await tester.pump();
    await g.up();
    await tester.pump();

    final moves = only('mouseMove');
    expect(moves, isNotEmpty);
    expect(
      moves.any((c) =>
          (asMap(c)['modifiers'] as int) & kEventFlagLeftMouseButton != 0),
      isTrue,
    );
  });

  testWidgets('滚轮：mouseWheel 的 deltaX/deltaY 取反', (tester) async {
    await pump(tester);
    calls.clear();

    final p = center(tester);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(p));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 50)));
    await tester.pump();

    final wheels = only('mouseWheel');
    expect(wheels, isNotEmpty);
    expect(asMap(wheels.last)['deltaY'], -50.0);
  });

  testWidgets('方向键：转发 key(type=0) 且 windowsKeyCode=VK_DOWN', (tester) async {
    await pump(tester);
    calls.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    final keys = only('key');
    expect(keys, isNotEmpty);
    final down = keys.firstWhere((c) => asMap(c)['type'] == 0);
    expect(asMap(down)['windowsKeyCode'], 0x28);
  });

  testWidgets('F5：转发 key 且 windowsKeyCode=VK_F5', (tester) async {
    await pump(tester);
    calls.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pump();

    final down =
        only('key').firstWhere((c) => asMap(c)['type'] == 0, orElse: () {
      fail('未捕获到 F5 的 key 调用');
    });
    expect(asMap(down)['windowsKeyCode'], 0x74);
  });

  testWidgets('可见字符不再走 CHAR 旁路：仅发 rawKeyDown(type=0)，不发 char(type=2)',
      (tester) async {
    // 文本插入统一改走「增量」通道（updateEditingValueWithDeltas → imeCommitText），
    // _onKey 不再为可见字符补发 KEYEVENT_CHAR，避免与增量重复插入。Windows 也一样。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pump(tester);
      calls.clear();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA, character: 'a');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);

      final keys = only('key');
      expect(keys.any((c) => asMap(c)['type'] == 0), isTrue,
          reason: '应有 rawKeyDown(type=0) 维持网页 keydown 语义');
      expect(keys.any((c) => asMap(c)['type'] == 2), isFalse,
          reason: '可见字符改走增量通道，不应再发 CHAR(type=2)');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('回车：除 rawKeyDown 外补发 char(0x0D, type=2) 供网页换行/提交',
      (tester) async {
    await pump(tester);
    calls.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final chars = only('key').where((c) => asMap(c)['type'] == 2).toList();
    expect(chars, isNotEmpty, reason: '回车应补发 char(0x0D)');
    expect(asMap(chars.first)['character'], 0x0D);
  });

  testWidgets('Ctrl+A：A 的 key 调用携带 Control 修饰符', (tester) async {
    await pump(tester);
    calls.clear();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);

    final aDown = only('key').where((c) {
      final m = asMap(c);
      return m['type'] == 0 && m['windowsKeyCode'] == 0x41;
    }).toList();
    expect(aDown, isNotEmpty);
    expect((asMap(aDown.first)['modifiers'] as int) & kEventFlagControlDown,
        isNot(0));

    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  testWidgets('IME 组字增量：composing 区间有效 → imeSetComposition', (tester) async {
    await pump(tester);
    await tester.tapAt(center(tester)); // 确保焦点 + 连接
    await tester.pump();
    calls.clear();

    // "" → "ni"（插入 + 组字区间 0..2）
    await sendDeltas([
      delta(
        oldText: '',
        deltaText: 'ni',
        deltaStart: 0,
        deltaEnd: 0,
        selection: 2,
        composingBase: 0,
        composingExtent: 2,
      ),
    ]);
    await tester.pump();

    final comp = only('imeSetComposition');
    expect(comp, isNotEmpty);
    expect(asMap(comp.last)['text'], 'ni');
  });

  testWidgets('IME 选词提交增量：组字区间替换为候选词且组字结束 → imeCommitText',
      (tester) async {
    await pump(tester);
    await tester.tapAt(center(tester));
    await tester.pump();
    calls.clear();

    // 1) 先组字 "ni"
    await sendDeltas([
      delta(
        oldText: '',
        deltaText: 'ni',
        deltaStart: 0,
        deltaEnd: 0,
        selection: 2,
        composingBase: 0,
        composingExtent: 2,
      ),
    ]);
    await tester.pump();
    // 2) 选词：把组字区间 (0,2) 替换为 "你好"，组字结束 (-1,-1)
    await sendDeltas([
      delta(
        oldText: 'ni',
        deltaText: '你好',
        deltaStart: 0,
        deltaEnd: 2,
        selection: 2,
        composingBase: -1,
        composingExtent: -1,
      ),
    ]);
    await tester.pump();

    final commit = only('imeCommitText');
    expect(commit, isNotEmpty);
    expect(asMap(commit.last)['text'], '你好');
  });

  testWidgets('英文逐字符增量：每个插入都提交 → imeCommitText', (tester) async {
    await pump(tester);
    await tester.tapAt(center(tester));
    await tester.pump();
    calls.clear();

    // 直接输入（无组字）："" → "a"
    await sendDeltas([
      delta(
        oldText: '',
        deltaText: 'a',
        deltaStart: 0,
        deltaEnd: 0,
        selection: 1,
        composingBase: -1,
        composingExtent: -1,
      ),
    ]);
    await tester.pump();

    final commit = only('imeCommitText');
    expect(commit, isNotEmpty);
    expect(asMap(commit.last)['text'], 'a');
  });

  testWidgets('失焦：上报 setFocus(false)', (tester) async {
    await pump(tester);
    calls.clear();

    tester.binding.focusManager.primaryFocus?.unfocus();
    await tester.pump();

    final focusCalls = only('setFocus');
    expect(focusCalls, isNotEmpty);
    expect(asMap(focusCalls.last)['focused'], false);
  });
}
