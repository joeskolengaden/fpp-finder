import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/history.dart';
import 'format.dart';
import 'theme.dart';

class DeviceCard extends StatelessWidget {
  const DeviceCard({super.key, required this.device});
  final Device device;

  Future<void> _openWeb(BuildContext context) async {
    final url = device.fpp?.url ?? 'http://${device.ip}/';
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  Future<void> _copyIp(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: device.ip));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Copied ${device.ip}'), duration: const Duration(seconds: 1)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<FppColors>()!;
    final scheme = Theme.of(context).colorScheme;
    final d = device;
    final f = d.fpp;
    final mono = const TextStyle(fontFamily: 'monospace', fontSize: 12.5);
    final muted = TextStyle(color: c.muted, fontSize: 12);

    final badges = <Widget>[
      if (d.isFpp) _Badge('FPP', bg: c.fpp, fg: const Color(0xFF04281A)),
      if (d.isNew) _Badge('NEW', bg: c.newBadge, fg: const Color(0xFF2B1A00)),
      if (!d.online) _Badge('OFFLINE', bg: c.off, fg: Colors.white),
    ];

    return Opacity(
      opacity: d.online ? 1 : .6,
      child: Card(
        key: ValueKey('device-${d.key}'),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        elevation: 0,
        color: d.isFpp ? Color.alphaBlend(c.fppBg, c.panel) : c.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: d.isFpp ? c.fpp.withValues(alpha: .55) : c.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(children: [
          if (d.isFpp)
            Positioned(
                left: 0, top: 0, bottom: 0, child: Container(width: 4, color: c.fpp)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                ...badges,
                Expanded(
                  child: Text(d.ip,
                      style: mono.copyWith(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface)),
                ),
              ]),
              if (d.hostname != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(d.hostname!, style: TextStyle(color: scheme.onSurface)),
                ),
              if (f != null) ...[
                const SizedBox(height: 6),
                Wrap(spacing: 14, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  if (f.version != null) _kv('version', f.version!, c),
                  if (f.modeLabel != null) _kv('mode', f.modeLabel!, c),
                  if (f.platform != null) _kv('platform', f.platform!, c),
                  if (f.model != null && f.model != f.platform) _kv('model', f.model!, c),
                  if (f.hostname != null) _kv('hostname', f.hostname!, c),
                  if (f.state != null) _kv('status', f.state!, c),
                  if (f.playlist != null) _kv('playlist', f.playlist!, c),
                ]),
                if (f.plugins.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(spacing: 6, runSpacing: 4, children: [
                      Text('plugins', style: muted),
                      for (final p in f.plugins) _Pill(p, c.fpp),
                    ]),
                  ),
              ],
              if (d.mac != null || d.vendor != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    [if (d.mac != null) d.mac!, if (d.vendor != null) d.vendor!]
                        .join('  ·  '),
                    style: mono.copyWith(color: c.muted),
                  ),
                ),
              if (d.ports.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(spacing: 4, runSpacing: 4, children: [
                    for (final p in d.ports)
                      _Port('${p.port}${p.name.isEmpty ? '' : ' ${p.name}'}', c),
                  ]),
                ),
              const SizedBox(height: 6),
              Text(
                'first seen ${fmtDateTime(d.firstSeen)}  ·  last seen ${fmtAgo(d.lastSeen)}',
                style: muted,
              ),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                if (d.isFpp)
                  TextButton(
                    onPressed: () => _openWeb(context),
                    style: TextButton.styleFrom(
                        foregroundColor: c.fpp, visualDensity: VisualDensity.compact),
                    child: const Text('Open web UI'),
                  ),
                TextButton(
                  onPressed: () => _copyIp(context),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  child: const Text('Copy IP'),
                ),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _kv(String k, String v, FppColors c) => Text.rich(TextSpan(children: [
        TextSpan(text: '$k ', style: TextStyle(color: c.muted, fontSize: 12)),
        TextSpan(
            text: v,
            style: TextStyle(color: c.fpp, fontWeight: FontWeight.w700, fontSize: 13)),
      ]));
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, {required this.bg, required this.fg});
  final String text;
  final Color bg;
  final Color fg;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
        child: Text(text,
            style: TextStyle(
                color: fg, fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: .4)),
      );
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
            border: Border.all(color: color), borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: TextStyle(color: color, fontSize: 11.5)),
      );
}

class _Port extends StatelessWidget {
  const _Port(this.text, this.c);
  final String text;
  final FppColors c;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        decoration: BoxDecoration(
            border: Border.all(color: c.line), borderRadius: BorderRadius.circular(4)),
        child: Text(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5)),
      );
}
