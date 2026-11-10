import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';

import '../core/subnet.dart';

/// Finds the phone's own Wi-Fi network(s): IPv4 address + netmask.
///
/// Sources, in order:
///  1. network_info_plus (Wi-Fi IP + submask; needs no location permission),
///  2. dart:io NetworkInterface.list() for any other private IPv4 address
///     (e.g. a USB/Ethernet adapter or hotspot), where the OS does not tell us
///     the netmask, so the common /24 is assumed.
/// We never scan outside these subnets, and subnets larger than /24 are capped
/// to the phone's own /24 by enumerateTargets().
Future<List<Iface>> detectInterfaces() async {
  final out = <Iface>[];
  String? wifiIp;
  try {
    final info = NetworkInfo();
    wifiIp = await info.getWifiIP();
    final mask = await info.getWifiSubmask();
    if (wifiIp != null) {
      final i = Iface.from('wifi', wifiIp, mask);
      if (i != null) out.add(i);
    }
  } catch (_) {}

  try {
    final ifs = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false);
    for (final nif in ifs) {
      for (final a in nif.addresses) {
        final ip = a.address;
        if (ip == wifiIp || !isPrivateOrLinkLocal(ip)) continue;
        if (out.any((o) => o.ip == ip)) continue;
        // Skip carrier-side/cellular and VPN-ish names; keep Wi-Fi/Ethernet/hotspot.
        if (RegExp(r'^(rmnet|ccmni|pdp|tun|ppp|utun|ipsec|lo)',
                caseSensitive: false)
            .hasMatch(nif.name)) {
          continue;
        }
        final i = Iface.from(nif.name, ip, null);
        if (i != null) out.add(i);
      }
    }
  } catch (_) {}
  return out;
}
