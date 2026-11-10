import 'dart:convert';

// OUI (MAC vendor) lookup against the bundled IEEE MA-L table
// (assets/oui-data.json, same file as the desktop app). Fully offline.

String? normalizeMac(String? mac) {
  if (mac == null) return null;
  final parts = mac.trim().toLowerCase().split(RegExp(r'[:\-.]'));
  if (parts.length == 3 && parts.every((p) => p.length == 4)) {
    final hex = parts.join();
    final out = <String>[];
    for (var i = 0; i < 12; i += 2) {
      out.add(hex.substring(i, i + 2));
    }
    return _validMac(out);
  }
  if (parts.length != 6) return null;
  return _validMac(parts.map((p) => p.length == 1 ? '0$p' : p).toList());
}

String? _validMac(List<String> octets) {
  final re = RegExp(r'^[0-9a-f]{2}$');
  if (!octets.every(re.hasMatch)) return null;
  return octets.join(':');
}

bool isMulticastOrBroadcastMac(String? mac) {
  final m = normalizeMac(mac);
  if (m == null) return true;
  if (m == 'ff:ff:ff:ff:ff:ff' || m == '00:00:00:00:00:00') return true;
  return (int.parse(m.substring(0, 2), radix: 16) & 1) == 1;
}

/// Locally administered MACs (randomised phone MACs, VMs) have no vendor.
bool isLocallyAdministered(String? mac) {
  final m = normalizeMac(mac);
  return m != null && (int.parse(m.substring(0, 2), radix: 16) & 2) == 2;
}

class OuiTable {
  OuiTable(this.names, this.map);

  final List<String> names;
  final Map<String, int> map;

  static final OuiTable empty = OuiTable(const [], const {});

  factory OuiTable.fromJsonString(String source) {
    final j = jsonDecode(source) as Map<String, dynamic>;
    final names = (j['names'] as List).cast<String>();
    final map = (j['map'] as Map).map((k, v) => MapEntry(k as String, v as int));
    return OuiTable(names, map);
  }

  String? lookupVendor(String? mac) {
    final m = normalizeMac(mac);
    if (m == null) return null;
    final prefix = m.substring(0, 8).replaceAll(':', '').toUpperCase();
    final idx = map[prefix];
    if (idx != null && idx < names.length) return names[idx];
    if (isLocallyAdministered(m)) return 'Private (randomised MAC)';
    return null;
  }
}
