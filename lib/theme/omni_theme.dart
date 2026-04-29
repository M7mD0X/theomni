import 'package:flutter/material.dart';

/// Omni-IDE design system.
/// Aesthetic: "Editorial Terminal" — warm-tinted near-black canvas,
/// a single marigold accent, hairline borders, generous negative space.
class T {
  // ── Palette ────────────────────────────────────────────────────────────
  // Warm near-blacks — slightly yellow-tinted for a paper-under-lamp feel
  static const bg = Color(0xFF0B0A08); // canvas
  static const s1 = Color(0xFF111010); // panels
  static const s2 = Color(0xFF171513); // raised surfaces
  static const s3 = Color(0xFF1F1C19); // input / cards
  static const s4 = Color(0xFF2A2621); // pressed / hover

  // Borders — hairline, warm
  static const border = Color(0xFF2C2823);
  static const borderHi = Color(0xFF3A352E);

  // Text
  static const text = Color(0xFFF2ECDE); // warm cream
  static const dim = Color(0xFFA9A08C); // 60%
  static const muted = Color(0xFF6C6454); // 40%
  static const faint = Color(0xFF453F35); // 25%

  // Single accent — marigold
  static const accent = Color(0xFFFFB347);
  static const accentHi = Color(0xFFFFC979);
  static const accentLo = Color(0xFFC88A2D);

  // Secondary accents (used sparingly, never together)
  static const coral = Color(0xFFE86A5C); // errors / destructive
  static const sage = Color(0xFF8FB184); // success / connected
  static const slate = Color(0xFF7FA6C7); // info / links
  static const rose = Color(0xFFC77A8E); // highlights

  // Tinted translucent layers (for subtle backgrounds)
  static const accentBg = Color(0x14FFB347); // 8%
  static const coralBg = Color(0x14E86A5C);
  static const sageBg = Color(0x148FB184);
  static const slateBg = Color(0x147FA6C7);

  // Pre-computed opacity variants (avoids withOpacity() in hot paths)
  // These are created once at class-load instead of per-frame allocations.
  static final accent40 = const Color(0x66FFB347); // accent @ 40%
  static final accent30 = const Color(0x4DFFB347); // accent @ 30%
  static final accent12 = const Color(0x1EFFB347); // accent @ 12%
  static final accent07 = const Color(0x12FFB347); // accent @ 7%
  static final sage40 = const Color(0x668FB184); // sage @ 40%
  static final sage60 = const Color(0x998FB184); // sage @ 60%
  static final coral40 = const Color(0x66E86A5C); // coral @ 40%
  static final slate30 = const Color(0x4D7FA6C7); // slate @ 30%

  // Syntax-ish file type colors (muted, not lurid)
  static const dartC = Color(0xFF7FA6C7);
  static const jsC = Color(0xFFE6C358);
  static const tsC = Color(0xFF6B96C9);
  static const htmlC = Color(0xFFD97A5C);
  static const cssC = Color(0xFF8BA7E8);
  static const pyC = Color(0xFFA2B37E);
  static const ktC = Color(0xFFB78FD4);
  static const mdC = Color(0xFFA9A08C);
  static const jsonC = Color(0xFFD4B87A);
  static const yamlC = Color(0xFFC77A8E);

  // ── Spacing scale ──────────────────────────────────────────────────────
  static const s_1 = 4.0;
  static const s_2 = 8.0;
  static const s_3 = 12.0;
  static const s_4 = 16.0;
  static const s_5 = 24.0;
  static const s_6 = 32.0;
  static const s_7 = 48.0;

  // ── Radii ──────────────────────────────────────────────────────────────
  static const r_sm = 4.0;
  static const r_md = 8.0;
  static const r_lg = 12.0;
  static const r_xl = 16.0;
  static const r_pill = 999.0;

  // ── Motion ─────────────────────────────────────────────────────────────
  static const dFast = Duration(milliseconds: 140);
  static const dMed = Duration(milliseconds: 220);
  static const dSlow = Duration(milliseconds: 360);
  static const eOut = Curves.easeOutCubic;
  static const eInOut = Curves.easeInOutCubic;

  // ── Typography ─────────────────────────────────────────────────────────
  // Display: Fraunces (editorial serif, italic optical sizes)
  // UI: Inter Tight
  // Mono: JetBrains Mono
  static TextStyle display({
    double size = 28,
    FontWeight weight = FontWeight.w600,
    Color color = text,
    FontStyle style = FontStyle.normal,
    double letterSpacing = -0.5,
  }) =>
      TextStyle(
        fontFamily: 'serif',
        fontSize: size,
        fontWeight: weight,
        color: color,
        fontStyle: style,
        letterSpacing: letterSpacing,
        height: 1.1,
      );

  static TextStyle ui({
    double size = 13,
    FontWeight weight = FontWeight.w400,
    Color color = text,
    double letterSpacing = 0,
    double height = 1.45,
  }) =>
      TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing,
        height: height,
      );

  static TextStyle mono({
    double size = 12.5,
    FontWeight weight = FontWeight.w400,
    Color color = text,
    double height = 1.55,
  }) =>
      TextStyle(
        fontFamily: 'monospace',
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
      );

  static TextStyle label({
    Color color = dim,
    double size = 10,
  }) =>
      TextStyle(
        fontSize: size,
        fontWeight: FontWeight.w700,
        color: color,
        letterSpacing: 1.6,
        height: 1,
      );

  // ── Theme ──────────────────────────────────────────────────────────────
  static ThemeData get theme {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        onPrimary: bg,
        secondary: rose,
        surface: s1,
        onSurface: text,
        error: coral,
      ),
      dividerColor: border,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: accent12,
        selectionHandleColor: accent,
      ),
      textTheme: TextTheme(
        bodyMedium: ui(),
        bodySmall: ui(size: 11, color: dim),
        titleMedium: display(size: 18),
      ),
    );
  }

  // ── File icon / color ──────────────────────────────────────────────────
  static IconData fileIcon(String name) {
    final ext = name.split('.').last.toLowerCase();
    switch (ext) {
      case 'dart':
        return Icons.circle_outlined;
      case 'js':
      case 'ts':
      case 'jsx':
      case 'tsx':
        return Icons.code;
      case 'json':
        return Icons.data_object;
      case 'md':
        return Icons.article_outlined;
      case 'yaml':
      case 'yml':
        return Icons.tune;
      case 'sh':
      case 'bash':
        return Icons.terminal;
      case 'html':
        return Icons.language;
      case 'css':
      case 'scss':
        return Icons.palette_outlined;
      case 'py':
        return Icons.functions;
      case 'kt':
        return Icons.extension_outlined;
      case 'txt':
        return Icons.notes;
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'webp':
      case 'svg':
        return Icons.image_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  static Color fileColor(String name) {
    final ext = name.split('.').last.toLowerCase();
    switch (ext) {
      case 'dart':
        return dartC;
      case 'js':
      case 'jsx':
        return jsC;
      case 'ts':
      case 'tsx':
        return tsC;
      case 'json':
        return jsonC;
      case 'md':
        return mdC;
      case 'yaml':
      case 'yml':
        return yamlC;
      case 'sh':
      case 'bash':
        return sage;
      case 'html':
        return htmlC;
      case 'css':
      case 'scss':
        return cssC;
      case 'py':
        return pyC;
      case 'kt':
        return ktC;
      default:
        return dim;
    }
  }
}
