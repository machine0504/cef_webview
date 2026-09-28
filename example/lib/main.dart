import 'dart:io';

import 'package:cef_webview/cef_webview.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import 'perf_overlay.dart';

bool cefReady = false;
String? cefInitError;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1) 初始化 CEF（尽早调用）。失败不阻断 UI，便于在未放置 CEF 二进制时调试界面。
  try {
    await CefWebview.ensureInitialized(const CefInitOptions(
      locale: 'zh-CN',
      userAgentSuffix: 'LzccbDigitalWork/1.0',
      logSeverity: CefLogSeverity.info,
      remoteDebuggingPort: 9222,
    ));
    cefReady = true;
  } catch (e) {
    cefInitError = '$e';
    debugPrint('CEF 初始化失败（可能未放置 CEF 二进制）：$e');
  }

  // 2) 配置全局链接拦截 + 白名单。
  CefLinkInterceptor.instance.configure(
    whitelist: ['example.com', 'example.com', 'flutter.dev'],
    onExternal: (url) => debugPrint('非白名单链接（可跳系统浏览器）：$url'),
  );

  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'cef_webview 示例',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static const _links = <String>[
    'https://example.com',
    'https://flutter.dev',
    'https://www.baidu.com', // 非白名单：走 onExternal
  ];

  @override
  Widget build(BuildContext context) {
    final interceptor = CefLinkInterceptor.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('内嵌浏览器（CEF 99 OSR）')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            shrinkWrap: true,
            children: [
              Container(
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cefReady
                      ? Colors.green.withOpacity(0.1)
                      : Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(cefReady ? Icons.check_circle : Icons.error,
                        color: cefReady ? Colors.green : Colors.red),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(cefReady
                          ? 'CEF 初始化成功，可测试 OSR 渲染'
                          : 'CEF 未初始化：${cefInitError ?? "未知"}'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: '① 原生 Flutter 输入框对比（先在这里打中文）',
                    hintText: '看输入法候选框是否跟随光标',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.keyboard),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LocalHtmlPage()),
                  ),
                  icon: const Icon(Icons.fact_check),
                  label: const Text('② HTML5 / CSS3 / 媒体 能力自动检测'),
                ),
              ),
              const Divider(height: 32),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('点击下列链接：白名单命中将唤起应用内嵌浏览器独立窗口，'
                    '否则交给系统处理。'),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: RichText(
                  text: TextSpan(
                    style: DefaultTextStyle.of(context).style,
                    children: [
                      const TextSpan(text: '示例富文本：欢迎访问 '),
                      TextSpan(
                        text: 'example.com',
                        style: const TextStyle(
                            color: Colors.blue,
                            decoration: TextDecoration.underline),
                        recognizer: TapGestureRecognizer()
                          ..onTap = interceptor.linkTap(
                              context, 'https://example.com',
                              title: '示例站点'),
                      ),
                      const TextSpan(text: ' 了解更多。'),
                    ],
                  ),
                ),
              ),
              ..._links.map((url) => ListTile(
                    leading: Icon(
                      interceptor.isWhitelisted(url)
                          ? Icons.verified_user
                          : Icons.open_in_new,
                      color: interceptor.isWhitelisted(url)
                          ? Colors.green
                          : Colors.orange,
                    ),
                    title: Text(url),
                    subtitle: Text(interceptor.isWhitelisted(url)
                        ? '白名单 → 内嵌浏览器'
                        : '非白名单 → 外部处理'),
                    onTap: () => interceptor.open(context, url),
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

/// 能力自动检测页：页面用 JS 检测 CEF 99 支持哪些 HTML5 标签 / 媒体编解码 /
/// JS API / CSS3 特性，把「不支持」清单实时回传 Flutter 顶栏，便于快速排查。
class LocalHtmlPage extends StatefulWidget {
  const LocalHtmlPage({super.key});

  @override
  State<LocalHtmlPage> createState() => _LocalHtmlPageState();
}

class _LocalHtmlPageState extends State<LocalHtmlPage> {
  CefWebviewController? _controller;
  String _status = '正在准备检测页…';

  int _capsTotal = 0;
  int _capsOk = 0;
  List<String> _unsupported = [];
  bool _capsReady = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final file = File('${Directory.systemTemp.path}/cef_webview_caps.html');
      await file.writeAsString(_testHtml);
      final url = Uri.file(file.path).toString();
      setState(() => _status = '加载 $url');

      final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
      final c = await CefWebviewController.create(
        url: url,
        width: 900,
        height: 600,
        devicePixelRatio: dpr,
      );

      // 接收页面自动检测的能力报告。
      c.addJavaScriptHandler('capabilities', (name, data) {
        if (data is! Map) return;
        final un = data['unsupported'];
        setState(() {
          _capsTotal = (data['total'] as num?)?.toInt() ?? 0;
          _capsOk = (data['supported'] as num?)?.toInt() ?? 0;
          _unsupported = un is List ? un.map((e) => '$e').toList() : <String>[];
          _capsReady = true;
        });
      });

      setState(() {
        _controller = c;
        _status = '已加载';
      });
    } catch (e) {
      setState(() => _status = '失败：$e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _showUnsupportedDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('不支持的能力（${_unsupported.length}）'),
        content: SizedBox(
          width: 420,
          child: _unsupported.isEmpty
              ? const Text('全部检测项均支持 ✓')
              : SingleChildScrollView(
                  child: Text(_unsupported.map((e) => '• $e').join('\n')),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('能力自动检测（CEF 99 OSR）'),
        actions: [
          IconButton(
            tooltip: '刷新重测',
            icon: const Icon(Icons.refresh),
            onPressed: c == null ? null : c.reload,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: _capsReady && _unsupported.isNotEmpty
                ? Colors.orange.withOpacity(0.12)
                : theme.colorScheme.surfaceVariant,
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('状态：$_status'),
                      if (_capsReady)
                        Text(
                          '能力检测：$_capsOk / $_capsTotal 支持'
                          '${_unsupported.isEmpty ? "（全部支持 ✓）" : "，不支持 ${_unsupported.length} 项"}',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: _unsupported.isEmpty
                                ? Colors.green.shade700
                                : Colors.deepOrange.shade700,
                          ),
                        ),
                    ],
                  ),
                ),
                if (_capsReady && _unsupported.isNotEmpty)
                  TextButton.icon(
                    onPressed: _showUnsupportedDialog,
                    icon: const Icon(Icons.list_alt),
                    label: const Text('查看清单'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: c == null
                ? const Center(child: CircularProgressIndicator())
                : Stack(
                    children: [
                      CefWebviewWidget(
                        controller: c,
                        placeholder: const _LoadingPlaceholder(),
                      ),
                      // Phase 0：性能基线探针（升级前后同页对比 FPS / 帧耗时）。
                      const Positioned.fill(child: PerfOverlay()),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 加载占位演示：渐变背景 + 加载指示，避免初始白屏「露馅」。
class _LoadingPlaceholder extends StatelessWidget {
  const _LoadingPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4F46E5), Color(0xFF9333EA), Color(0xFFEC4899)],
        ),
      ),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(
                  color: Colors.white, strokeWidth: 3),
            ),
            SizedBox(height: 20),
            Text('页面加载中…',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1)),
          ],
        ),
      ),
    );
  }
}

const String _testHtml = r'''
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CEF 99 能力自动检测</title>
<style>
  :root{ --brand:#4f46e5; --brand2:#9333ea; --accent:#ec4899;
    --ok:#16a34a; --no:#dc2626; --ink:#0f172a; --muted:#64748b; --line:#e2e8f0; }
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:"PingFang SC","Noto Sans CJK SC","Microsoft YaHei",system-ui,sans-serif;
    color:var(--ink); background:linear-gradient(180deg,#f8fafc,#eef2ff); padding-bottom:60px;}
  header{position:sticky;top:0;z-index:10;color:#fff;padding:18px 24px;
    background:linear-gradient(120deg,var(--brand),var(--brand2) 55%,var(--accent));
    box-shadow:0 4px 14px rgba(2,6,23,.18);}
  header h1{font-size:20px}
  header p{opacity:.9;font-size:13px;margin-top:4px}
  main{max-width:960px;margin:0 auto;padding:20px}
  .summary{display:flex;gap:14px;flex-wrap:wrap;margin:8px 0 18px}
  .stat{flex:1;min-width:140px;background:#fff;border-radius:14px;padding:16px 18px;
    box-shadow:0 6px 18px rgba(2,6,23,.07);text-align:center}
  .stat .num{font-size:30px;font-weight:800}
  .stat .lbl{color:var(--muted);font-size:13px;margin-top:2px}
  .stat.ok .num{color:var(--ok)} .stat.no .num{color:var(--no)}
  .card{background:#fff;border-radius:14px;padding:18px;margin:14px 0;
    box-shadow:0 6px 18px rgba(2,6,23,.06)}
  .card h2{font-size:16px;margin-bottom:12px;display:flex;align-items:center;gap:8px}
  .card h2 .dot{width:8px;height:8px;border-radius:50%;
    background:linear-gradient(120deg,var(--brand),var(--accent))}
  .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:8px}
  .item{display:flex;align-items:center;gap:8px;padding:8px 12px;border-radius:9px;
    font-size:13.5px;background:#f8fafc;border:1px solid var(--line)}
  .item.bad{background:#fef2f2;border-color:#fecaca}
  .badge{width:20px;height:20px;border-radius:50%;display:grid;place-items:center;
    color:#fff;font-size:12px;font-weight:700;flex:none}
  .badge.y{background:var(--ok)} .badge.n{background:var(--no)}
  video,audio{width:100%;border-radius:10px;background:#000;margin-top:8px}
  audio{background:#f1f5f9}
  .note{color:var(--muted);font-size:12.5px;margin-top:8px}
</style>
</head>
<body>
<header>
  <h1>CEF 99 能力自动检测报告</h1>
  <p>打开即自动检测；红色为「不支持」。结果已同步到上方 Flutter 顶栏。</p>
</header>
<main>
  <div class="summary">
    <div class="stat"><div class="num" id="s-total">…</div><div class="lbl">检测项</div></div>
    <div class="stat ok"><div class="num" id="s-ok">…</div><div class="lbl">支持</div></div>
    <div class="stat no"><div class="num" id="s-no">…</div><div class="lbl">不支持</div></div>
  </div>

  <div class="card" id="card-unsupported" style="display:none">
    <h2><span class="dot"></span>不支持的能力</h2>
    <div class="grid" id="list-unsupported"></div>
  </div>

  <div class="card">
    <h2><span class="dot"></span>真实媒体标签（video / audio）</h2>
    <div class="note">下方为真实 &lt;video&gt;/&lt;audio&gt; 元素。控件能显示=标签支持；能否播放取决于编解码与网络（离线时只验证元素与编解码探测）。</div>
    <video id="vid" controls preload="metadata" poster="">
      <source src="https://www.w3schools.com/html/mov_bbb.mp4" type="video/mp4">
      您的内核不支持 video 标签。
    </video>
    <audio id="aud" controls preload="metadata">
      <source src="https://www.w3schools.com/html/horse.mp3" type="audio/mpeg">
      您的内核不支持 audio 标签。
    </audio>
  </div>

  <div class="card"><h2><span class="dot"></span>HTML5 标签</h2><div class="grid" id="g-tags"></div></div>
  <div class="card"><h2><span class="dot"></span>媒体编解码（canPlayType）</h2><div class="grid" id="g-codec"></div></div>
  <div class="card"><h2><span class="dot"></span>JavaScript API</h2><div class="grid" id="g-api"></div></div>
  <div class="card"><h2><span class="dot"></span>CSS3 / 布局特性</h2><div class="grid" id="g-css"></div></div>
</main>

<script>
  function attempt(fn){ try{ return !!fn(); }catch(e){ return false; } }
  function cssSupport(p, v){ return attempt(function(){ return window.CSS && CSS.supports && CSS.supports(p, v); }); }

  var groups = { tags:[], codec:[], api:[], css:[] };
  function add(group, name, ok){ groups[group].push({ name:name, ok:!!ok }); }

  // ---- HTML5 标签 ----
  add('tags','<video>', !!document.createElement('video').canPlayType);
  add('tags','<audio>', !!document.createElement('audio').canPlayType);
  add('tags','<canvas> 2D', attempt(function(){ return document.createElement('canvas').getContext('2d'); }));
  add('tags','<svg>', !!(document.createElementNS && document.createElementNS('http://www.w3.org/2000/svg','svg').createSVGRect));
  add('tags','<dialog>', 'showModal' in document.createElement('dialog'));
  add('tags','<details>', 'open' in document.createElement('details'));
  add('tags','<template>', 'content' in document.createElement('template'));
  add('tags','<datalist>', 'options' in document.createElement('datalist'));
  add('tags','<progress>', 'value' in document.createElement('progress'));
  add('tags','<meter>', 'value' in document.createElement('meter'));
  add('tags','<picture>', 'HTMLPictureElement' in window);
  add('tags','Shadow DOM', 'attachShadow' in document.createElement('div'));
  add('tags','Custom Elements', 'customElements' in window);
  add('tags','<input type=date>', (function(){ var i=document.createElement('input'); i.setAttribute('type','date'); return i.type==='date'; })());
  add('tags','<input type=color>', (function(){ var i=document.createElement('input'); i.setAttribute('type','color'); return i.type==='color'; })());
  add('tags','contenteditable', 'isContentEditable' in document.createElement('div'));

  // ---- 媒体编解码 ----
  var v=document.createElement('video'), a=document.createElement('audio');
  add('codec','视频 H.264 (MP4)', v.canPlayType('video/mp4; codecs="avc1.42E01E"')!=='');
  add('codec','视频 H.265/HEVC', v.canPlayType('video/mp4; codecs="hvc1"')!=='');
  add('codec','视频 VP8 (WebM)', v.canPlayType('video/webm; codecs="vp8"')!=='');
  add('codec','视频 VP9 (WebM)', v.canPlayType('video/webm; codecs="vp9"')!=='');
  add('codec','视频 AV1', v.canPlayType('video/mp4; codecs="av01.0.05M.08"')!=='');
  add('codec','视频 Ogg/Theora', v.canPlayType('video/ogg; codecs="theora"')!=='');
  add('codec','音频 MP3', a.canPlayType('audio/mpeg')!=='');
  add('codec','音频 AAC', a.canPlayType('audio/aac')!=='');
  add('codec','音频 Ogg/Vorbis', a.canPlayType('audio/ogg; codecs="vorbis"')!=='');
  add('codec','音频 WAV', a.canPlayType('audio/wav; codecs="1"')!=='');
  add('codec','音频 FLAC', a.canPlayType('audio/flac')!=='');
  add('codec','MSE 流媒体', 'MediaSource' in window);

  // ---- JS API ----
  add('api','Promise', typeof Promise!=='undefined');
  add('api','async/await', attempt(function(){ eval('(async()=>{})'); return true; }));
  add('api','fetch', typeof fetch!=='undefined');
  add('api','XMLHttpRequest', 'XMLHttpRequest' in window);
  add('api','WebSocket', 'WebSocket' in window);
  add('api','localStorage', attempt(function(){ return window.localStorage; }));
  add('api','sessionStorage', attempt(function(){ return window.sessionStorage; }));
  add('api','IndexedDB', !!window.indexedDB);
  add('api','Web Worker', 'Worker' in window);
  add('api','Service Worker', 'serviceWorker' in navigator);
  add('api','WebAssembly', typeof WebAssembly!=='undefined');
  add('api','WebGL', attempt(function(){ return document.createElement('canvas').getContext('webgl'); }));
  add('api','WebGL2', attempt(function(){ return document.createElement('canvas').getContext('webgl2'); }));
  add('api','Web Audio', !!(window.AudioContext||window.webkitAudioContext));
  add('api','getUserMedia 摄像头/麦克风', !!(navigator.mediaDevices&&navigator.mediaDevices.getUserMedia));
  add('api','WebRTC (RTCPeerConnection)', 'RTCPeerConnection' in window);
  add('api','Geolocation 定位', 'geolocation' in navigator);
  add('api','Notification 通知', 'Notification' in window);
  add('api','Clipboard 剪贴板', !!navigator.clipboard);
  add('api','FileReader', 'FileReader' in window);
  add('api','Blob / URL.createObjectURL', 'Blob' in window && !!(window.URL&&URL.createObjectURL));
  add('api','requestAnimationFrame', 'requestAnimationFrame' in window);
  add('api','IntersectionObserver', 'IntersectionObserver' in window);
  add('api','ResizeObserver', 'ResizeObserver' in window);
  add('api','MutationObserver', 'MutationObserver' in window);
  add('api','History pushState', !!(window.history&&history.pushState));
  add('api','Intl 国际化', typeof Intl!=='undefined');
  add('api','structuredClone', typeof structuredClone!=='undefined');

  // ---- CSS ----
  add('css','Flexbox', cssSupport('display','flex'));
  add('css','Grid', cssSupport('display','grid'));
  add('css','CSS 变量 var()', cssSupport('--x','0'));
  add('css','gap 间距', cssSupport('gap','1px'));
  add('css','position: sticky', cssSupport('position','sticky'));
  add('css','aspect-ratio', cssSupport('aspect-ratio','1 / 1'));
  add('css','transform 3D', cssSupport('transform','translate3d(0,0,0)'));
  add('css','transition', cssSupport('transition','all .2s'));
  add('css','animation', cssSupport('animation-name','x'));
  add('css','filter', cssSupport('filter','blur(2px)'));
  add('css','backdrop-filter', cssSupport('backdrop-filter','blur(2px)')||cssSupport('-webkit-backdrop-filter','blur(2px)'));
  add('css','clip-path', cssSupport('clip-path','circle(50%)'));
  add('css','mask', cssSupport('mask','none')||cssSupport('-webkit-mask','none'));
  add('css','conic-gradient', cssSupport('background-image','conic-gradient(#000,#fff)'));
  add('css','线性/径向渐变', cssSupport('background-image','linear-gradient(#000,#fff)'));
  add('css','object-fit', cssSupport('object-fit','cover'));
  add('css',':has() 选择器', attempt(function(){ document.querySelector(':has(*)'); return true; }));
  add('css','容器查询 container', cssSupport('container-type','inline-size'));
  add('css','scroll-behavior', cssSupport('scroll-behavior','smooth'));
  add('css','gap(flex)', cssSupport('column-gap','1px'));

  // ---- 渲染 + 汇总 ----
  function render(group, elId){
    var el=document.getElementById(elId); var html='';
    groups[group].forEach(function(r){
      html += '<div class="item'+(r.ok?'':' bad')+'">'
            + '<span class="badge '+(r.ok?'y':'n')+'">'+(r.ok?'✓':'✕')+'</span>'
            + '<span>'+r.name+'</span></div>';
    });
    el.innerHTML=html;
  }
  render('tags','g-tags'); render('codec','g-codec'); render('api','g-api'); render('css','g-css');

  var all=[].concat(groups.tags,groups.codec,groups.api,groups.css);
  var unsupported=all.filter(function(r){return !r.ok;}).map(function(r){return r.name;});
  document.getElementById('s-total').textContent=all.length;
  document.getElementById('s-ok').textContent=all.length-unsupported.length;
  document.getElementById('s-no').textContent=unsupported.length;
  if(unsupported.length){
    document.getElementById('card-unsupported').style.display='block';
    document.getElementById('list-unsupported').innerHTML=unsupported.map(function(n){
      return '<div class="item bad"><span class="badge n">✕</span><span>'+n+'</span></div>';
    }).join('');
  }

  function report(){
    if(window.cefBridge){
      window.cefBridge.callHandler('capabilities',{
        total: all.length,
        supported: all.length-unsupported.length,
        unsupported: unsupported
      });
    }
  }
  // cefBridge 注入可能略晚于脚本执行，重试几次确保上报成功。
  var tries=0;
  (function push(){ if(window.cefBridge||tries>20){ report(); } else { tries++; setTimeout(push,100); } })();
</script>
</body>
</html>
''';
