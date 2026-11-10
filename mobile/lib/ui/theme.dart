import 'package:flutter/material.dart';

/// Colours taken 1:1 from the desktop app's stylesheet.
class FppColors extends ThemeExtension<FppColors> {
  const FppColors({
    required this.fpp,
    required this.fppBg,
    required this.newBadge,
    required this.off,
    required this.panel,
    required this.line,
    required this.muted,
  });

  final Color fpp;
  final Color fppBg;
  final Color newBadge;
  final Color off;
  final Color panel;
  final Color line;
  final Color muted;

  static const dark = FppColors(
    fpp: Color(0xFF2EE59D),
    fppBg: Color(0x1A2EE59D),
    newBadge: Color(0xFFFFB020),
    off: Color(0xFF5B6877),
    panel: Color(0xFF161C24),
    line: Color(0xFF243040),
    muted: Color(0xFF8394A7),
  );

  static const light = FppColors(
    fpp: Color(0xFF0A9E66),
    fppBg: Color(0x1A0A9E66),
    newBadge: Color(0xFFB36B00),
    off: Color(0xFF9AA7B5),
    panel: Color(0xFFFFFFFF),
    line: Color(0xFFD9E1EA),
    muted: Color(0xFF5D6F82),
  );

  @override
  FppColors copyWith() => this;

  @override
  FppColors lerp(ThemeExtension<FppColors>? other, double t) => this;
}

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final ext = dark ? FppColors.dark : FppColors.light;
  final accent = dark ? const Color(0xFF3DA9FC) : const Color(0xFF0B6BCB);
  final bg = dark ? const Color(0xFF0F1419) : const Color(0xFFF4F7FA);
  final text = dark ? const Color(0xFFDBE4EE) : const Color(0xFF1B2733);
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    scaffoldBackgroundColor: bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: accent,
      brightness: b,
    ).copyWith(
      primary: accent,
      surface: ext.panel,
      onSurface: text,
      outline: ext.line,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: ext.panel,
      foregroundColor: text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    dividerColor: ext.line,
    extensions: [ext],
  );
}
