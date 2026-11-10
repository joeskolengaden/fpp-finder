import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../app/controller.dart';
import 'device_card.dart';
import 'theme.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});
  final ScanController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  ScanController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_changed);
    // CI hook: the iOS simulator smoke test launches with FPP_NO_AUTOSCAN=1 so it
    // does not sweep the CI runner's network. Real users never set this.
    final skip = Platform.environment['FPP_NO_AUTOSCAN'] == '1';
    if (!skip) WidgetsBinding.instance.addPostFrameCallback((_) => c.scan());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = state == AppLifecycleState.resumed;
    c.setForeground(fg);
    if (fg && !c.scanning) {
      // Coming back after a while: refresh right away.
      final last = c.last?.ended;
      if (last == null ||
          DateTime.now().millisecondsSinceEpoch - last > 30 * 1000) {
        c.scan();
      }
    }
  }

  String _stageLabel() {
    final p = c.progress;
    if (p == null) return 'Scanning…';
    final base = switch (p.stage) {
      'interfaces' => 'Finding your Wi-Fi network',
      'mdns' => 'Listening for Bonjour/mDNS',
      'sweep' => 'Sweeping the subnet',
      'ports' => 'Checking open ports',
      'fpp' => 'Asking devices if they are FPP',
      'names' => 'Resolving names',
      _ => 'Scanning',
    };
    return p.total > 1 ? '$base (${p.done}/${p.total})' : '$base…';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<FppColors>()!;
    final devices = c.visible;
    final last = c.last;
    final ifaces = last?.interfaces ?? const [];
    final p = c.progress;

    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Text('❄ ', style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          const Text('FPP Finder', style: TextStyle(fontWeight: FontWeight.w700)),
        ]),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              key: const Key('rescan'),
              onPressed: c.scanning ? null : c.scan,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Rescan'),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: c.scanning
              ? LinearProgressIndicator(
                  minHeight: 3,
                  value: (p != null && p.total > 1) ? p.done / p.total : null)
              : const SizedBox(height: 3),
        ),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: TextField(
            onChanged: c.setQuery,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Filter IP, name, MAC, vendor, plugin…',
              prefixIcon: const Icon(Icons.search, size: 20),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            FilterChip(
              key: const Key('fppOnly'),
              label: const Text('FPP only'),
              selected: c.fppOnly,
              onSelected: c.setFppOnly,
            ),
            const SizedBox(width: 8),
            FilterChip(
              label: const Text('Pin FPP on top'),
              selected: c.pinFpp,
              onSelected: c.setPinFpp,
            ),
            const SizedBox(width: 8),
            FilterChip(
              label: const Text('Show offline'),
              selected: c.showOffline,
              onSelected: c.setShowOffline,
            ),
            const SizedBox(width: 12),
            Text('Auto-rescan ', style: TextStyle(color: colors.muted)),
            DropdownButton<int>(
              value: c.intervalSec,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 0, child: Text('Off')),
                DropdownMenuItem(value: 15, child: Text('15 s')),
                DropdownMenuItem(value: 30, child: Text('30 s')),
                DropdownMenuItem(value: 60, child: Text('1 min')),
                DropdownMenuItem(value: 120, child: Text('2 min')),
                DropdownMenuItem(value: 300, child: Text('5 min')),
              ],
              onChanged: (v) => c.setInterval(v ?? 0),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              c.scanning
                  ? _stageLabel()
                  : c.error != null
                      ? 'Scan failed: ${c.error}'
                      : last == null
                          ? 'Not scanned yet'
                          : '${c.fppCount} FPP · ${devices.length} shown'
                              ' · ${last.devices.where((d) => d.online).length} online',
              style: TextStyle(color: colors.muted, fontSize: 12.5),
            ),
          ),
        ),
        if (ifaces.isNotEmpty)
          SizedBox(
            height: 30,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              children: [
                for (final i in ifaces)
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 9),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(color: i.linkLocal ? colors.newBadge : colors.line),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text('${i.name} ${i.ip} · ${i.cidr}',
                        style: TextStyle(color: colors.muted, fontSize: 12)),
                  ),
              ],
            ),
          ),
        if (last != null && last.warnings.contains('no-wifi'))
          _Warn(
              'No Wi-Fi network found. Connect to the same Wi-Fi as your FPP controllers (and on iPhone allow Local Network access), then tap Rescan.',
              colors.newBadge),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => c.scan(),
            child: devices.isEmpty
                ? ListView(children: [
                    Padding(
                      padding: const EdgeInsets.all(40),
                      child: Center(
                        child: Text(
                          c.scanning ? 'Looking for devices…' : 'No devices to show.',
                          style: TextStyle(color: colors.muted),
                        ),
                      ),
                    ),
                  ])
                : ListView.builder(
                    padding: const EdgeInsets.only(top: 4, bottom: 12),
                    itemCount: devices.length,
                    itemBuilder: (_, i) => DeviceCard(device: devices[i]),
                  ),
          ),
        ),
        Container(
          width: double.infinity,
          color: colors.panel,
          padding: EdgeInsets.fromLTRB(
              14, 6, 14, 6 + MediaQuery.of(context).padding.bottom),
          child: Text(
            'Read-only: only TCP connects, mDNS queries and HTTP GETs on your own Wi-Fi subnet. Nothing is ever written to a device.',
            style: TextStyle(color: colors.muted, fontSize: 11),
          ),
        ),
      ]),
    );
  }
}

class _Warn extends StatelessWidget {
  const _Warn(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
            border: Border.all(color: color), borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: TextStyle(color: color, fontSize: 12.5)),
      );
}
