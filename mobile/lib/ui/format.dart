String two(int n) => n.toString().padLeft(2, '0');

/// "just now", "5 min ago", "3 h ago", "2 d ago".
String fmtAgo(int ms, {int? now}) {
  final diff = ((now ?? DateTime.now().millisecondsSinceEpoch) - ms) ~/ 1000;
  if (diff < 20) return 'just now';
  if (diff < 90) return '${diff}s ago';
  if (diff < 3600) return '${diff ~/ 60} min ago';
  if (diff < 86400) return '${diff ~/ 3600} h ago';
  return '${diff ~/ 86400} d ago';
}

/// "2026-11-11 14:05" in local time.
String fmtDateTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}
