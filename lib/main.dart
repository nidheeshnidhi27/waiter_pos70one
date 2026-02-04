import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const JooposApp());
}

class JooposApp extends StatelessWidget {
  const JooposApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'pos70one',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      debugShowCheckedModeBanner: false,
      home: const WebShell(),
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
  static const MethodChannel _deeplinkChannel = MethodChannel(
    'com.joopos/deeplink',
  );
  final TextEditingController _urlController = TextEditingController();
  bool _showUrlBar = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (req) async {
            final uri = Uri.parse(req.url);
            final handled = await _handleDeepLinkUri(uri);
            return handled
                ? NavigationDecision.prevent
                : NavigationDecision.navigate;
          },
          onPageStarted: (url) {
            _injectPolyfills();
          },
          onPageFinished: (url) {
            _injectPolyfills();
          },
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
      await _controller.loadRequest(
        Uri.parse(saved),
        headers: {
          'User-Agent': Platform.isIOS ? 'Flutter iOS' : 'Flutter Android',
        },
      );
    }
  }

  void _injectPolyfills() {
    const notifJs = """
    (function(){try{var R=function(){try{if(window.AndroidBell&&AndroidBell.ring){AndroidBell.ring();}}catch(e){}};if(typeof window.Notification==='undefined'){var N=function(t,o){R();};N.permission='granted';N.requestPermission=function(cb){var r='granted';if(cb)cb(r);return Promise.resolve(r);};window.Notification=N;}else{var _N=window.Notification;window.Notification=function(t,o){R();return new _N(t,o)};window.Notification.requestPermission=function(cb){return _N.requestPermission(cb)}}}catch(e){}})();
    """;
    const popupJs = """
    (function(){try{var _open=window.open;window.open=function(u,n,s){try{if(u){location.href=u;return null}}catch(e){}try{return _open.apply(window,arguments)}catch(e){return null}};document.addEventListener('click',function(e){try{var a=e.target&&e.target.closest?e.target.closest('a[target=\"_blank\"]'):null;if(a&&a.href){e.preventDefault();location.href=a.href}}catch(_){}} ,true);}catch(e){}})();
    """;
    _controller.runJavaScript(notifJs);
    _controller.runJavaScript(popupJs);
  }

  Future<bool> _handleDeepLinkUri(Uri uri) async {
    if (uri.scheme.isEmpty) return false;
    if (uri.scheme == 'intent') {
      try {
        final dataParam = uri.queryParameters['base_url'] ?? uri.toString();
        final deep = Uri.parse(
          'app://open.my.app?base_url=${Uri.encodeComponent(dataParam)}',
        );
        await _processPrintDeepLink(deep);
        return true;
      } catch (_) {
        return false;
      }
    }
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
        'equal_split_payable_invoice',
        'print_today_petty_cash',
        'daily_summary_report',
        'online_report',
        'offline_report',
        'booking_report',
        'mainsaway',
        'print_',
      ].any(u.contains);
      if (isPrint) {
        final deep = Uri.parse(
          'app://open.my.app?base_url=${Uri.encodeComponent(uri.toString())}',
        );
        await _processPrintDeepLink(deep);
        return true;
      }
    }
    return false;
  }

  Future<void> _processPrintDeepLink(Uri deep) async {
    var baseUrl = deep.queryParameters['base_url'];
    if (baseUrl == null || baseUrl.isEmpty) return;
    baseUrl = Uri.decodeComponent(baseUrl);
    if (baseUrl.startsWith('http://')) {
      baseUrl = baseUrl.replaceFirst('http://', 'https://');
    }
    if (baseUrl.contains('invoice_print') && !baseUrl.contains('split_id=')) {
      baseUrl = baseUrl.contains('?')
          ? '$baseUrl&split_id=1'
          : '$baseUrl?split_id=1';
    }
    if (baseUrl.contains('print_today_petty_cash')) {
      final idx = baseUrl.indexOf('&');
      if (idx != -1) {
        baseUrl = baseUrl.substring(0, idx);
      }
    }
    final resp = await http.get(Uri.parse(baseUrl));
    if (resp.statusCode != 200) return;
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final type = (json['print_type'] ?? '').toString().toLowerCase();
    if (type.contains('kot')) {
      await _processKot(json);
      return;
    }
    final printer = _selectPrinter(json);
    final printerType = printer.$3;
    if ((printer.$1?.isNotEmpty ?? false) && printerType != 'usb') {
      final bytes = await _buildEscPos(json);
      await _printNetwork(printer.$1!, printer.$2 ?? 9100, bytes);
    } else if (printerType == 'usb' || (printer.$1?.trim().isEmpty ?? true)) {
      final bytes = await _buildEscPos(json);
      if (Platform.isAndroid) {
        try {
          const chan = MethodChannel('com.joopos/escpos');
          await chan.invokeMethod('printUsbBytes', bytes);
        } catch (_) {}
      }
    }
  }

  Future<void> _processKot(Map<String, dynamic> json) async {
    final detailsDyn = json['details'];
    if (detailsDyn is! Map<String, dynamic>) return;
    final printers = (json['printers'] ?? []) as List;
    int kotCopies = 1;
    try {
      final ps = (json['printsettings'] ?? []) as List;
      if (ps.isNotEmpty) {
        kotCopies =
            int.tryParse((ps.first['kot_print_copies'] ?? '1').toString()) ?? 1;
      }
    } catch (_) {}
    for (final key in detailsDyn.keys) {
      final objectDetails = (detailsDyn[key] ?? {}) as Map<String, dynamic>;
      dynamic printerObj = objectDetails['printer'];
      int printerId = -1;
      if (printerObj is List && printerObj.isNotEmpty) {
        final v = printerObj.first;
        if (v is num) printerId = v.toInt();
        if (v is String) printerId = int.tryParse(v) ?? -1;
      } else if (printerObj is num) {
        printerId = printerObj.toInt();
      } else if (printerObj is String) {
        printerId = int.tryParse(printerObj) ?? -1;
      }
      Map<String, dynamic>? printerDetails;
      for (final p in printers) {
        if (p is Map<String, dynamic>) {
          final pid = int.tryParse(p['id'].toString()) ?? -1;
          if (pid == printerId) {
            printerDetails = p;
            break;
          }
        }
      }
      final ip = (printerDetails?['ip'] ?? '').toString();
      final port =
          int.tryParse((printerDetails?['port'] ?? '9100').toString()) ?? 9100;
      final pType = (printerDetails?['type'] ?? 'network')
          .toString()
          .toLowerCase();
      final bytes = await _buildKotBytes(json, objectDetails);
      for (int i = 0; i < kotCopies; i++) {
        if (pType == 'usb' || ip.trim().isEmpty) {
          if (Platform.isAndroid) {
            try {
              const chan = MethodChannel('com.joopos/escpos');
              await chan.invokeMethod('printUsbBytes', bytes);
            } catch (_) {}
          }
        } else {
          await _printNetwork(ip, port, bytes);
        }
        await Future.delayed(const Duration(milliseconds: 15));
      }
    }
  }

  Future<List<int>> _buildKotBytes(
    Map<String, dynamic> response,
    Map<String, dynamic> objectDetails,
  ) async {
    final profile = await CapabilityProfile.load();
    final g = Generator(PaperSize.mm58, profile);
    final out = <int>[];
    out.addAll(
      g.text(
        'KOT :Kitchen',
        styles: const PosStyles(
          align: PosAlign.center,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
    );
    out.addAll(g.hr());
    final order =
        (objectDetails['order_details'] ?? {}) as Map<String, dynamic>;
    final type = (order['order_type'] ?? '').toString();
    final orderNo = (order['order_no'] ?? '').toString();
    final orderTime = (order['order_time'] ?? '').toString();
    final waiter = (order['waiter_name'] ?? '').toString();
    final customer = (order['customer_name'] ?? '').toString();
    final phone = (order['customer_phone'] ?? '').toString();
    final address = (order['customer_address'] ?? '').toString();
    final postcode = (order['postcode'] ?? '').toString();
    final tableno = (order['tableno'] ?? '').toString();
    final seats = int.tryParse((order['table_seats'] ?? '0').toString()) ?? 0;
    if (orderTime.isNotEmpty) out.addAll(g.text('Date: $orderTime'));
    if (customer.isNotEmpty) out.addAll(g.text('Customer: $customer'));
    if (address.isNotEmpty && address.toLowerCase() != 'null') {
      out.addAll(g.text('Address: $address, $postcode'));
    }
    if (phone.isNotEmpty && phone.toLowerCase() != 'null') {
      out.addAll(g.text('Phone: $phone'));
    }
    if (waiter.isNotEmpty) out.addAll(g.text('Served by: $waiter'));
    if (type.toLowerCase() == 'dinein') {
      final cleanTable = tableno
          .replaceAll(RegExp('table', caseSensitive: false), '')
          .trim();
      out.addAll(
        g.text(
          'Table: ${cleanTable.isEmpty ? '-' : cleanTable}',
          styles: const PosStyles(
            height: PosTextSize.size2,
            width: PosTextSize.size2,
          ),
        ),
      );
      out.addAll(g.text('Seats: ${seats > 0 ? seats : '-'}'));
    }
    out.addAll(
      g.text(
        '${type.toUpperCase()} #$orderNo',
        styles: const PosStyles(
          align: PosAlign.center,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
    );
    out.addAll(g.hr());
    final categories =
        (objectDetails['categories'] ?? {}) as Map<String, dynamic>;
    for (final cat in categories.keys) {
      final itemsObj = (categories[cat] ?? {}) as Map<String, dynamic>;
      for (final itemId in itemsObj.keys) {
        final item = (itemsObj[itemId] ?? {}) as Map<String, dynamic>;
        final qty = (item['quantity'] ?? '').toString();
        final name = (item['item'] ?? '').toString();
        out.addAll(
          g.text(
            '$qty x $name',
            styles: const PosStyles(height: PosTextSize.size2),
          ),
        );
        final addonObj = item['addon'];
        if (addonObj is Map<String, dynamic>) {
          for (final ak in addonObj.keys) {
            final a = (addonObj[ak] ?? {}) as Map<String, dynamic>;
            final adName = (a['ad_name'] ?? '').toString();
            final adQty = (a['ad_qty'] ?? '').toString();
            if (adName.isNotEmpty && adQty.isNotEmpty && adQty != '0') {
              out.addAll(g.text('  + $adQty x $adName'));
            }
          }
        } else if (addonObj is List) {
          for (final a in addonObj) {
            if (a is Map<String, dynamic>) {
              final adName = (a['ad_name'] ?? '').toString();
              final adQty = (a['ad_qty'] ?? '').toString();
              if (adName.isNotEmpty && adQty.isNotEmpty && adQty != '0') {
                out.addAll(g.text('  + $adQty x $adName'));
              }
            }
          }
        }
        final other = (item['other'] ?? '').toString();
        if (other.isNotEmpty) out.addAll(g.text('Note: $other'));
        out.addAll(g.feed(1));
      }
    }
    out.addAll(g.hr());
    final instr = (order['instruction'] ?? '').toString();
    if (instr.isNotEmpty) {
      out.addAll(g.text('Special Instruction: $instr'));
      out.addAll(g.hr());
    }
    final reqTime = (order['deliverytime'] ?? '').toString();
    if (reqTime.isNotEmpty && reqTime.toLowerCase() != 'null') {
      out.addAll(g.text('Requested for: $reqTime'));
      out.addAll(g.hr());
    }
    out.addAll(g.text('Printed : ${DateTime.now()}'));
    out.addAll(g.feed(2));
    out.addAll(g.cut());
    return out;
  }

  (String?, int?, String) _selectPrinter(Map<String, dynamic> json) {
    String ip = '';
    int port = 9100;
    String type = 'network';
    try {
      final printers = (json['printers'] ?? []) as List;
      final setup = (json['printersetup'] ?? []) as List;
      if (setup.isNotEmpty) {
        final useId = int.tryParse(setup.first.toString()) ?? setup.first;
        for (final p in printers) {
          final pid = p['id'];
          if (pid == useId) {
            ip = (p['ip'] ?? '').toString();
            port = int.tryParse((p['port'] ?? '9100').toString()) ?? 9100;
            type = (p['type'] ?? 'network').toString();
            break;
          }
        }
      }
    } catch (_) {}
    return (ip, port, type);
  }

  Future<List<int>> _buildEscPos(Map<String, dynamic> json) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm58, profile);
    final bytes = <int>[];
    final outlets = (json['outlets'] ?? []) as List;
    if (outlets.isNotEmpty) {
      final outlet = outlets.first as Map<String, dynamic>;
      final name = (outlet['name'] ?? '').toString();
      final address = (outlet['address'] ?? '').toString();
      final phone = (outlet['phone'] ?? '').toString();
      bytes.addAll(
        generator.text(
          name,
          styles: const PosStyles(
            align: PosAlign.center,
            height: PosTextSize.size2,
            width: PosTextSize.size2,
            underline: true,
          ),
        ),
      );
      bytes.addAll(
        generator.text(
          address,
          styles: const PosStyles(align: PosAlign.center),
        ),
      );
      if (phone.isNotEmpty) {
        bytes.addAll(
          generator.text(
            'Phone: $phone',
            styles: const PosStyles(align: PosAlign.center),
          ),
        );
      }
    }
    final data = (json['data'] ?? {}) as Map<String, dynamic>;
    final type = (json['print_type'] ?? '').toString().toLowerCase();
    final orderNo = (data['order_no'] ?? '').toString();
    final orderType = (data['order_type'] ?? '').toString();
    final date = (data['order_time'] ?? '').toString();
    if (type.contains('invoice')) {
      bytes.addAll(
        generator.text(
          'Invoice: #$orderNo',
          styles: const PosStyles(bold: true),
        ),
      );
    } else if (type.contains('kot')) {
      bytes.addAll(generator.text('KOT', styles: const PosStyles(bold: true)));
    }
    if (orderType.isNotEmpty) {
      final ot = orderType.toUpperCase();
      bytes.addAll(generator.text('Order Type: $ot'));
    }
    final customerName = (data['customer_name'] ?? '').toString();
    final custAddress = (data['customer_address'] ?? '').toString();
    final postcode = (data['postcode'] ?? '').toString();
    final custPhone = (data['customer_phone'] ?? '').toString();
    if (customerName.isNotEmpty) {
      bytes.addAll(generator.text('Customer: $customerName'));
    }
    if (custAddress.isNotEmpty && custAddress.toLowerCase() != 'null') {
      bytes.addAll(generator.text('Address: $custAddress, $postcode'));
    }
    if (custPhone.isNotEmpty && custPhone.toLowerCase() != 'null') {
      bytes.addAll(generator.text('Phone: $custPhone'));
    }
    if (date.isNotEmpty) bytes.addAll(generator.text('Date: $date'));
    bytes.addAll(generator.hr());

    final dynamic detailsDyn = json['details'];
    if (detailsDyn is Map<String, dynamic>) {
      for (final catKey in detailsDyn.keys) {
        final itemsObj = (detailsDyn[catKey] ?? {}) as Map<String, dynamic>;
        for (final itemKey in itemsObj.keys) {
          final item = (itemsObj[itemKey] ?? {}) as Map<String, dynamic>;
          _appendItemBytes(generator, bytes, item);
        }
      }
    } else if (detailsDyn is List) {
      for (final it in detailsDyn) {
        if (it is Map<String, dynamic>) {
          _appendItemBytes(generator, bytes, it);
        }
      }
    }

    bytes.addAll(generator.hr());
    final subtotal = (data['subtotal'] ?? '').toString();
    final bagFee = (data['bag_fee'] ?? '').toString();
    final delFee = (data['delivery_charge'] ?? '').toString();
    final tip = (data['tip_amount'] ?? '').toString();
    final discount = (data['discount'] ?? '').toString();
    final total = (data['total'] ?? '').toString();
    if (subtotal.isNotEmpty) {
      bytes.addAll(
        generator.row([
          PosColumn(text: 'Subtotal', width: 8),
          PosColumn(
            text: '£$subtotal',
            width: 4,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]),
      );
    }
    if (bagFee.isNotEmpty) {
      bytes.addAll(
        generator.row([
          PosColumn(text: 'Bag Fee', width: 8),
          PosColumn(
            text: '£$bagFee',
            width: 4,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]),
      );
    }
    if (delFee.isNotEmpty) {
      bytes.addAll(
        generator.row([
          PosColumn(text: 'Delivery Fee', width: 8),
          PosColumn(
            text: '£$delFee',
            width: 4,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]),
      );
    }
    if (tip.isNotEmpty) {
      bytes.addAll(
        generator.row([
          PosColumn(text: 'Tip Amount', width: 8),
          PosColumn(
            text: '£$tip',
            width: 4,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]),
      );
    }
    if (discount.isNotEmpty) {
      bytes.addAll(
        generator.row([
          PosColumn(text: 'Discount', width: 8),
          PosColumn(
            text: '£$discount',
            width: 4,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]),
      );
    }
    if (total.isNotEmpty) {
      bytes.addAll(
        generator.row([
          PosColumn(
            text: 'Total PAYABLE',
            width: 8,
            styles: const PosStyles(bold: true),
          ),
          PosColumn(
            text: '£$total',
            width: 4,
            styles: const PosStyles(align: PosAlign.right, bold: true),
          ),
        ]),
      );
    }
    bytes.addAll(generator.feed(2));
    bytes.addAll(generator.cut());
    return bytes;
  }

  void _appendItemBytes(
    Generator generator,
    List<int> bytes,
    Map<String, dynamic> item,
  ) {
    try {
      final name = (item['item'] ?? item['name'] ?? '').toString();
      final qty =
          double.tryParse(
            (item['quantity'] ?? item['qty'] ?? '0').toString(),
          ) ??
          0;
      final amount =
          double.tryParse(
            (item['amount'] ?? item['price'] ?? '0').toString(),
          ) ??
          0;
      bytes.addAll(
        generator.row([
          PosColumn(text: '${qty.toStringAsFixed(0)} x $name', width: 8),
          PosColumn(
            text: amount > 0 ? '£${(qty * amount).toStringAsFixed(2)}' : '',
            width: 4,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]),
      );
      final addonObjDyn = item['addon'];
      if (addonObjDyn is Map<String, dynamic>) {
        for (final ak in addonObjDyn.keys) {
          final ad = (addonObjDyn[ak] ?? {}) as Map<String, dynamic>;
          final adName = (ad['ad_name'] ?? '').toString();
          final adQtyStr = (ad['ad_qty'] ?? '').toString();
          final adPriceStr = (ad['ad_price'] ?? '').toString();
          if (adName.isEmpty || adQtyStr.isEmpty || adQtyStr == '0') continue;
          final adQty = double.tryParse(adQtyStr) ?? 0;
          final adPrice = double.tryParse(adPriceStr) ?? 0;
          bytes.addAll(
            generator.row([
              PosColumn(
                text: '  + ${adQty.toStringAsFixed(0)} x $adName',
                width: 8,
              ),
              PosColumn(
                text: adPrice > 0
                    ? '£${(adQty * adPrice).toStringAsFixed(2)}'
                    : '',
                width: 4,
                styles: const PosStyles(align: PosAlign.right),
              ),
            ]),
          );
        }
      } else if (addonObjDyn is List) {
        for (final ad in addonObjDyn) {
          if (ad is Map<String, dynamic>) {
            final adName = (ad['ad_name'] ?? '').toString();
            final adQtyStr = (ad['ad_qty'] ?? '').toString();
            final adPriceStr = (ad['ad_price'] ?? '').toString();
            if (adName.isEmpty || adQtyStr.isEmpty || adQtyStr == '0') continue;
            final adQty = double.tryParse(adQtyStr) ?? 0;
            final adPrice = double.tryParse(adPriceStr) ?? 0;
            bytes.addAll(
              generator.row([
                PosColumn(
                  text: '  + ${adQty.toStringAsFixed(0)} x $adName',
                  width: 8,
                ),
                PosColumn(
                  text: adPrice > 0
                      ? '£${(adQty * adPrice).toStringAsFixed(2)}'
                      : '',
                  width: 4,
                  styles: const PosStyles(align: PosAlign.right),
                ),
              ]),
            );
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _printNetwork(String ip, int port, List<int> data) async {
    try {
      final socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 4),
      );
      socket.add(data);
      await socket.flush();
      await Future.delayed(const Duration(milliseconds: 300));
      await socket.close();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_showUrlBar)
              Container(
                width: double.infinity,
                height: double.infinity,
                color: Colors.black.withOpacity(0.7),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Image.asset(
                            'assets/logo/joopay_logo.png',
                            height: 80,
                          ),
                          const SizedBox(height: 20),
                          const Text(
                            'Enter Restaurant URL',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _urlController,
                            decoration: const InputDecoration(
                              labelText: 'Restaurant URL',
                              hintText: 'https://your-domain.com',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.zero,
                              ),
                            ),
                            onSubmitted: (_) => _go(),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: ElevatedButton(
                              onPressed: _go,
                              style: ElevatedButton.styleFrom(
                                shape: const RoundedRectangleBorder(
                                  borderRadius: BorderRadius.zero,
                                ),
                              ),
                              child: const Text('Continue'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _go() async {
    var u = _urlController.text.trim();
    if (u.isEmpty) return;
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('web_url', u);
    setState(() => _showUrlBar = false);
    await _controller.loadRequest(
      Uri.parse(u),
      headers: {
        'User-Agent': Platform.isIOS ? 'Flutter iOS' : 'Flutter Android',
      },
    );
  }
}
