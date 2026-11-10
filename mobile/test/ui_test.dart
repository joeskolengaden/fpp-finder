import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpp_finder/core/fpp.dart';
import 'package:fpp_finder/core/history.dart';
import 'package:fpp_finder/ui/device_card.dart';
import 'package:fpp_finder/ui/theme.dart';

String fx(String n) => File('test/fixtures/$n').readAsStringSync();

List<Device> sample() {
  final fppInfo = buildFppInfo(
    ip: '192.168.1.50',
    version: classifyVersion(fx('fpp-version.json')),
    status: classifyStatus(fx('fpp-status.json')),
    multisync: classifyMultiSync(fx('fpp-multisync.json'), '192.168.1.50'),
    plugins: classifyPlugins(fx('fpp-plugins.json')),
    interfaces: classifyInterfaces(fx('fpp-interfaces.json')),
  );
  final now = DateTime.now().millisecondsSinceEpoch;
  return [
    Device(
      key: '04:23:22:aa:bb:cc',
      ip: '192.168.1.50',
      mac: '04:23:22:aa:bb:cc',
      hostname: 'FPP',
      vendor: 'Texas Instruments',
      ports: const [OpenPort(22, 'ssh'), OpenPort(80, 'http')],
      fpp: fppInfo,
      firstSeen: now - 86400000 * 3,
      lastSeen: now,
      online: true,
      isNew: true,
    ),
    Device(
      key: 'ip:192.168.1.1',
      ip: '192.168.1.1',
      hostname: 'router.lan',
      ports: const [OpenPort(53, 'dns'), OpenPort(80, 'http'), OpenPort(443, 'https')],
      firstSeen: now - 86400000 * 30,
      lastSeen: now,
      online: true,
    ),
    Device(
      key: 'ip:192.168.1.77',
      ip: '192.168.1.77',
      firstSeen: now - 86400000 * 2,
      lastSeen: now - 3600000 * 5,
    ),
  ];
}

Widget host(Widget child, Brightness b) => MaterialApp(
      theme: buildTheme(b),
      home: Scaffold(body: ListView(children: [child])),
    );

Future<void> loadFonts() async {
  Future<void> load(String family, String path) async {
    final f = File(path);
    if (!f.existsSync()) return;
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    await loader.load();
  }

  await load('Roboto', '/System/Library/Fonts/Supplemental/Arial.ttf');
  await load('monospace', '/System/Library/Fonts/Supplemental/Courier New.ttf');
}

void main() {
  testWidgets('FPP card shows badges, details, plugins and actions', (tester) async {
    final d = sample().first;
    await tester.pumpWidget(host(DeviceCard(device: d), Brightness.dark));
    expect(find.text('FPP'), findsNWidgets(2)); // badge + hostname
    expect(find.text('NEW'), findsOneWidget);
    expect(find.text('192.168.1.50'), findsOneWidget);
    expect(find.textContaining('5.4.1', findRichText: true), findsOneWidget);
    expect(find.textContaining('player', findRichText: true), findsOneWidget);
    expect(find.textContaining('platform BeagleBone', findRichText: true), findsOneWidget);
    expect(find.text('pixelselect'), findsOneWidget);
    expect(find.text('Open web UI'), findsOneWidget);
    expect(find.text('Copy IP'), findsOneWidget);
    expect(find.textContaining('Texas Instruments'), findsOneWidget);
    expect(find.textContaining('first seen'), findsOneWidget);
  });

  testWidgets('non-FPP card has no FPP badge or web button; offline is dimmed + badged',
      (tester) async {
    final list = sample();
    await tester.pumpWidget(host(
        Column(children: [DeviceCard(device: list[1]), DeviceCard(device: list[2])]),
        Brightness.light));
    expect(find.text('FPP'), findsNothing);
    expect(find.text('Open web UI'), findsNothing);
    expect(find.text('OFFLINE'), findsOneWidget);
    expect(find.text('Copy IP'), findsNWidgets(2));
  });

  testWidgets('Copy IP puts the address on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    await tester.pumpWidget(host(DeviceCard(device: sample().first), Brightness.dark));
    await tester.tap(find.text('Copy IP'));
    await tester.pump();
    expect(copied, '192.168.1.50');
    expect(find.text('Copied 192.168.1.50'), findsOneWidget);
  });

  // Local visual check only: FPP_SHOT=/path/out_prefix flutter test test/ui_test.dart
  final shot = Platform.environment['FPP_SHOT'];
  if (shot != null) {
    for (final b in [Brightness.dark, Brightness.light]) {
      testWidgets('screenshot $b', (tester) async {
        await tester.runAsync(loadFonts);
        tester.view.physicalSize = const Size(1080, 1500);
        tester.view.devicePixelRatio = 2.5;
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: buildTheme(b).copyWith(
                textTheme: buildTheme(b).textTheme.apply(fontFamily: 'Roboto')),
            home: Scaffold(
              body: SafeArea(child: ListView(children: [for (final d in sample()) DeviceCard(device: d)])),
            ),
          ),
        ));
        await tester.pump();
        await tester.runAsync(() async {
          final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final img = await boundary.toImage(pixelRatio: 1);
          final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!;
          File('$shot-${b.name}.png').writeAsBytesSync(bytes.buffer.asUint8List());
        });
      });
    }
  }
}
