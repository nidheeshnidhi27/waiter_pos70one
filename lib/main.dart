// ================== FULL WORKING MAIN.DART ==================
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:http/http.dart' as http;
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const JooposApp());
}

class JooposApp extends StatelessWidget {
  const JooposApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: WebShell(),
    );
  }
}

class WebShell extends StatefulWidget {
  const WebShell({super.key});
  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  late final WebViewController _controller;

  static const MethodChannel _deeplinkChannel =
      MethodChannel('com.joopos/deeplink');

  final TextEditingController _urlController = TextEditingController();
  bool _showUrlBar = false;

  @override
  void initState() {
    super.initState();

    late final PlatformWebViewControllerCreationParams params;

    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    _controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
          Platform.isIOS ? "Flutter iOS POS70ONE" : "Flutter Android POS70ONE")
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (req) async {
            final uri = Uri.parse(req.url);
            final handled = await _handleDeepLinkUri(uri);
            return handled
                ? NavigationDecision.prevent
                : NavigationDecision.navigate;
          },
          onPageStarted: (_) => _injectPolyfills(),
          onPageFinished: (_) => _injectPolyfills(),
          onWebResourceError: (error) {
            setState(() {
              _showUrlBar = true;
              _urlController.text = error.url ?? '';
            });
          },
        ),
      );

    _loadSavedUrl();

    _deeplinkChannel.setMethodCallHandler((call) async {
      if (call.method == 'open') {
        final url = (call.arguments as String?) ?? '';
        if (url.isNotEmpty) {
          await _processPrintDeepLink(Uri.parse(url));
        }
      }
    });
  }

  // ================= LOAD URL =================

  Future<void> _loadSavedUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('web_url') ?? '';

    if (saved.isEmpty) {
      setState(() {
        _showUrlBar = true;
        _urlController.text = 'https://';
      });
    } else {
      setState(() => _showUrlBar = false);
      await _controller.loadRequest(Uri.parse(saved));
    }
  }

  // ================= JS POLYFILLS =================

  void _injectPolyfills() {
    const notifJs = """
    (function(){
      try{
        if(typeof Notification==='undefined'){
          window.Notification=function(){};
          Notification.permission='granted';
          Notification.requestPermission=function(cb){
            if(cb)cb('granted');
            return Promise.resolve('granted');
          };
        }
      }catch(e){}
    })();
    """;

    const popupJs = """
    (function(){
      try{
        var _open=window.open;
        window.open=function(u,n,s){
          try{if(u){location.href=u;return null}}catch(e){}
          try{return _open.apply(window,arguments)}catch(e){return null}
        };
      }catch(e){}
    })();
    """;

    _controller.runJavaScript(notifJs);
    _controller.runJavaScript(popupJs);
  }

  // ================= DEEP LINK HANDLING =================

  Future<bool> _handleDeepLinkUri(Uri uri) async {
    if (uri.scheme == 'app') {
      await _processPrintDeepLink(uri);
      return true;
    }

    if (uri.scheme == 'http' || uri.scheme == 'https') {
      final u = uri.toString().toLowerCase();

      final isPrint = [
        'invoice_print',
        'reprint_kot',
        'online_kot',
        'online_invoice',
        'print_today_petty_cash',
        'daily_summary_report',
        'mainsaway',
        'print_'
      ].any(u.contains);

      if (isPrint) {
        final deep = Uri.parse(
            'app://open.my.app?base_url=${Uri.encodeComponent(uri.toString())}');
        await _processPrintDeepLink(deep);
        return true;
      }
    }
    return false;
  }

  // ================= PRINT PROCESS =================

  Future<void> _processPrintDeepLink(Uri deep) async {
    var baseUrl = deep.queryParameters['base_url'];
    if (baseUrl == null) return;

    baseUrl = Uri.decodeComponent(baseUrl);

    final resp = await http.get(Uri.parse(baseUrl));
    if (resp.statusCode != 200) return;

    final json = jsonDecode(resp.body);

    final printer = _selectPrinter(json);
    final bytes = await _buildEscPos(json);

    if (printer.$1 != null && printer.$1!.isNotEmpty) {
      await _printNetwork(printer.$1!, printer.$2 ?? 9100, bytes);
    } else {
      if (Platform.isAndroid) {
        const chan = MethodChannel('com.joopos/escpos');
        await chan.invokeMethod('printUsbBytes', bytes);
      }
    }
  }

  (String?, int?, String) _selectPrinter(Map<String, dynamic> json) {
    try {
      final printers = (json['printers'] ?? []) as List;
      if (printers.isNotEmpty) {
        final p = printers.first;
        return (
          (p['ip'] ?? '').toString(),
          int.tryParse((p['port'] ?? '9100').toString()) ?? 9100,
          (p['type'] ?? 'network').toString()
        );
      }
    } catch (_) {}
    return ('', 9100, 'network');
  }

  // ================= ESC POS =================

  Future<List<int>> _buildEscPos(Map<String, dynamic> json) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm58, profile);

    final bytes = <int>[];
    bytes.addAll(generator.text("POS70ONE RECEIPT",
        styles: const PosStyles(align: PosAlign.center, bold: true)));

    final data = (json['data'] ?? {}) as Map<String, dynamic>;
    final orderNo = (data['order_no'] ?? '').toString();

    bytes.addAll(generator.text("Order: $orderNo"));
    bytes.addAll(generator.hr());
    bytes.addAll(generator.feed(2));
    bytes.addAll(generator.cut());

    return bytes;
  }

  // ================= NETWORK PRINT =================

  Future<void> _printNetwork(
      String ip, int port, List<int> data) async {
    try {
      final socket =
          await Socket.connect(ip, port, timeout: const Duration(seconds: 4));
      socket.add(data);
      await socket.flush();
      await socket.close();
    } catch (_) {}
  }

  // ================= UI =================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_showUrlBar)
            Center(
              child: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(controller: _urlController),
                    ElevatedButton(onPressed: _go, child: const Text("Continue"))
                  ],
                ),
              ),
            )
        ],
      ),
    );
  }

  Future<void> _go() async {
    var u = _urlController.text.trim();
    if (!u.startsWith('http')) u = 'https://$u';

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('web_url', u);

    setState(() => _showUrlBar = false);
    await _controller.loadRequest(Uri.parse(u));
  }
}
