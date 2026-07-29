import 'package:flutter/material.dart';

/// Mostro design system tokens.
///
/// All colors are defined here — zero hardcoded colors in widgets.
/// Access via `Theme.of(context).extension<AppColors>()!`.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.backgroundDark,
    required this.backgroundCard,
    required this.backgroundInput,
    required this.backgroundElevated,
    required this.mostroGreen,
    required this.mostroGreenBright,
    required this.sellColor,
    required this.destructiveRed,
    required this.purpleButton,
    required this.tealAccent,
    required this.blueAccent,
    required this.textPrimary,
    required this.textSecondary,
    required this.textSubtle,
    required this.textDisabled,
    required this.textLink,
    required this.messageSent,
    required this.messageReceived,
    required this.systemMessage,
    required this.badgeGold,
    required this.warningAmber,
  });

  final Color backgroundDark;
  final Color backgroundCard;
  final Color backgroundInput;
  final Color backgroundElevated;
  final Color mostroGreen;
  final Color mostroGreenBright;
  final Color sellColor;
  final Color destructiveRed;
  final Color purpleButton;
  final Color tealAccent;
  final Color blueAccent;
  final Color textPrimary;
  final Color textSecondary;
  final Color textSubtle;
  final Color textDisabled;
  final Color textLink;
  final Color messageSent;
  final Color messageReceived;
  final Color systemMessage;
  /// Dark-gold color used for the notification count badge.
  final Color badgeGold;
  /// Amber used for time-sensitive warnings (running timers, backup nags).
  final Color warningAmber;

  /// Status chip colors — [background, text].
  static const statusPending = (Color(0xFF854D0E), Color(0xFFFCD34D));
  static const statusWaiting = (Color(0xFF7C2D12), Color(0xFFFED7AA));
  static const statusActive = (Color(0xFF1E3A8A), Color(0xFF93C5FD));
  static const statusSuccess = (Color(0xFF065F46), Color(0xFF6EE7B7));
  static const statusDispute = (Color(0xFF7F1D1D), Color(0xFFFCA5A5));
  static const statusSettled = (Color(0xFF581C87), Color(0xFFC084FC));
  static const statusInactive = (Color(0xFF1F2937), Color(0xFFD1D5DB));

  @override
  AppColors copyWith({
    Color? backgroundDark,
    Color? backgroundCard,
    Color? backgroundInput,
    Color? backgroundElevated,
    Color? mostroGreen,
    Color? mostroGreenBright,
    Color? sellColor,
    Color? destructiveRed,
    Color? purpleButton,
    Color? tealAccent,
    Color? blueAccent,
    Color? textPrimary,
    Color? textSecondary,
    Color? textSubtle,
    Color? textDisabled,
    Color? textLink,
    Color? messageSent,
    Color? messageReceived,
    Color? systemMessage,
    Color? badgeGold,
    Color? warningAmber,
  }) {
    return AppColors(
      backgroundDark: backgroundDark ?? this.backgroundDark,
      backgroundCard: backgroundCard ?? this.backgroundCard,
      backgroundInput: backgroundInput ?? this.backgroundInput,
      backgroundElevated: backgroundElevated ?? this.backgroundElevated,
      mostroGreen: mostroGreen ?? this.mostroGreen,
      mostroGreenBright: mostroGreenBright ?? this.mostroGreenBright,
      sellColor: sellColor ?? this.sellColor,
      destructiveRed: destructiveRed ?? this.destructiveRed,
      purpleButton: purpleButton ?? this.purpleButton,
      tealAccent: tealAccent ?? this.tealAccent,
      blueAccent: blueAccent ?? this.blueAccent,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textSubtle: textSubtle ?? this.textSubtle,
      textDisabled: textDisabled ?? this.textDisabled,
      textLink: textLink ?? this.textLink,
      messageSent: messageSent ?? this.messageSent,
      messageReceived: messageReceived ?? this.messageReceived,
      systemMessage: systemMessage ?? this.systemMessage,
      badgeGold: badgeGold ?? this.badgeGold,
      warningAmber: warningAmber ?? this.warningAmber,
    );
  }

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      backgroundDark: Color.lerp(backgroundDark, other.backgroundDark, t)!,
      backgroundCard: Color.lerp(backgroundCard, other.backgroundCard, t)!,
      backgroundInput: Color.lerp(backgroundInput, other.backgroundInput, t)!,
      backgroundElevated:
          Color.lerp(backgroundElevated, other.backgroundElevated, t)!,
      mostroGreen: Color.lerp(mostroGreen, other.mostroGreen, t)!,
      mostroGreenBright:
          Color.lerp(mostroGreenBright, other.mostroGreenBright, t)!,
      sellColor: Color.lerp(sellColor, other.sellColor, t)!,
      destructiveRed: Color.lerp(destructiveRed, other.destructiveRed, t)!,
      purpleButton: Color.lerp(purpleButton, other.purpleButton, t)!,
      tealAccent: Color.lerp(tealAccent, other.tealAccent, t)!,
      blueAccent: Color.lerp(blueAccent, other.blueAccent, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textSubtle: Color.lerp(textSubtle, other.textSubtle, t)!,
      textDisabled: Color.lerp(textDisabled, other.textDisabled, t)!,
      textLink: Color.lerp(textLink, other.textLink, t)!,
      messageSent: Color.lerp(messageSent, other.messageSent, t)!,
      messageReceived: Color.lerp(messageReceived, other.messageReceived, t)!,
      systemMessage: Color.lerp(systemMessage, other.systemMessage, t)!,
      badgeGold: Color.lerp(badgeGold, other.badgeGold, t)!,
      warningAmber: Color.lerp(warningAmber, other.warningAmber, t)!,
    );
  }
}

// ── Order Book redesign palette ───────────────────────────────────────────────

/// Palette of the "Mostro UX Redesign" mock (Claude Design, screen
/// #3 · Order book). Applied only to the redesigned Order Book screen while
/// the rest of the app migrates screen by screen; dark values follow the mock
/// except where the mock fails WCAG AA (4.5:1) on its real rendered surface —
/// [textTertiary] and [red] are lightened just enough to pass. The mock is
/// dark-only, so [light] is a legibility mapping onto the existing light
/// surfaces, darkened where needed to pass AA. Every text-role/surface pair is
/// locked by `test/core/order_book_palette_contrast_test.dart`.
@immutable
class OrderBookPalette {
  const OrderBookPalette({
    required this.bg,
    required this.bgCard,
    required this.bgElevated,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.tabInactive,
    required this.green,
    required this.greenDim,
    required this.gold,
    required this.goldDim,
    required this.blue,
    required this.blueFill,
    required this.amber,
    required this.red,
  });

  final Color bg;
  final Color bgCard;
  final Color bgElevated;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  /// Unselected BUY/SELL tab label. In dark this keeps the mock's dimmed
  /// value (a deliberately de-emphasized state); in light it must clear
  /// WCAG AA since the tab is an interactive control.
  final Color tabInactive;
  final Color green;
  final Color greenDim;
  final Color gold;
  final Color goldDim;
  final Color blue;
  final Color blueFill;
  final Color amber;
  final Color red;

  static const dark = OrderBookPalette(
    bg: Color(0xFF0F151C),
    bgCard: Color(0xFF1A2029),
    bgElevated: Color(0xFF222A35),
    border: Color(0x0FFFFFFF), // rgba(255,255,255,0.06)
    textPrimary: Color(0xFFF2F4F7),
    textSecondary: Color(0xFFA8B0BC),
    // Mock #6B7280 is 3.4:1 on the card — lightened to pass AA (4.8:1).
    textTertiary: Color(0xFF848C9A),
    tabInactive: Color(0xFF4A5060),
    green: Color(0xFF8FE04A),
    greenDim: Color(0xFF2A4015),
    gold: Color(0xFFFFC940),
    goldDim: Color(0xFF3A2D0A),
    blue: Color(0xFF7BB4F0),
    blueFill: Color(0xFF1E2B42),
    amber: Color(0xFFE89C3C),
    // Mock #E5484D is 3.7:1 on its 13% pill fill — lightened to pass AA.
    red: Color(0xFFF27D81),
  );

  static const light = OrderBookPalette(
    bg: Color(0xFFFFFFFF),
    bgCard: Color(0xFFF5F5F5),
    bgElevated: Color(0xFFEEEEEE),
    border: Color(0x14000000),
    textPrimary: Color(0xFF1A1A1A),
    textSecondary: Color(0xFF666666),
    textTertiary: Color(0xFF696969),
    tabInactive: Color(0xFF666666),
    green: Color(0xFF426800),
    greenDim: Color(0x26426800),
    gold: Color(0xFF7E5C09),
    goldDim: Color(0x267E5C09),
    blue: Color(0xFF35638F),
    blueFill: Color(0x2635638F),
    amber: Color(0xFF845010),
    red: Color(0xFFAE3333),
  );

  static OrderBookPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

// ── Spacing tokens ─────────────────────────────────────────────────────────────

abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

// ── Responsive breakpoints ────────────────────────────────────────────────────

/// Logical-pixel breakpoints for responsive layouts.
///
/// - < [tablet]  → mobile   (single-column, overlay drawer, bottom nav)
/// - [tablet] – [desktop] → tablet (2-column grid, side panel)
/// - ≥ [desktop] → desktop  (3-column grid, persistent sidebar, no bottom nav)
abstract final class AppBreakpoints {
  static const double tablet = 600;
  static const double desktop = 1200;
}

// ── Border-radius tokens ───────────────────────────────────────────────────────

abstract final class AppRadius {
  static const double card = 12;
  static const double button = 8;
  static const double chip = 6;
  static const double bubble = 16;
  static const double input = 8;
}

// ── Predefined colour instances ────────────────────────────────────────────────

const _dark = AppColors(
  backgroundDark: Color(0xFF1B1E28),
  backgroundCard: Color(0xFF1E2230),
  backgroundInput: Color(0xFF252A3A),
  backgroundElevated: Color(0xFF2A2D35),
  mostroGreen: Color(0xFF8CC63F),
  mostroGreenBright: Color(0xFFA5FF00),
  sellColor: Color(0xFFFF8A8A),
  destructiveRed: Color(0xFFD84D4D),
  purpleButton: Color(0xFF8359C2),
  tealAccent: Color(0xFF2DA69D),
  blueAccent: Color(0xFF35485E),
  textPrimary: Color(0xFFFFFFFF),
  textSecondary: Color(0xFFB0B3C6),
  textSubtle: Color(0xFF9A9A9C),
  textDisabled: Color(0xFF6C757D),
  textLink: Color(0xFF8CC63F),
  messageSent: Color(0xFF8359C2),
  messageReceived: Color(0xFF4B6349),
  systemMessage: Color(0xFF2A2D35),
  badgeGold: Color(0xFFB8860B),
  warningAmber: Color(0xFFE89C3C),
);

const _light = AppColors(
  backgroundDark: Color(0xFFFFFFFF),
  backgroundCard: Color(0xFFF5F5F5),
  backgroundInput: Color(0xFFEEEEEE),
  backgroundElevated: Color(0xFFE0E0E0),
  mostroGreen: Color(0xFF8CC63F),
  mostroGreenBright: Color(0xFF6A9E00),
  sellColor: Color(0xFFFF8A8A),
  destructiveRed: Color(0xFFD84D4D),
  purpleButton: Color(0xFF8359C2),
  tealAccent: Color(0xFF2DA69D),
  blueAccent: Color(0xFF35485E),
  textPrimary: Color(0xFF1A1A1A),
  textSecondary: Color(0xFF666666),
  textSubtle: Color(0xFF888888),
  textDisabled: Color(0xFFAAAAAA),
  textLink: Color(0xFF6A9E00),
  messageSent: Color(0xFF8359C2),
  messageReceived: Color(0xFF4B6349),
  systemMessage: Color(0xFFE0E0E0),
  badgeGold: Color(0xFFB8860B),
  warningAmber: Color(0xFFC97B1F),
);

// ── ThemeData factories ────────────────────────────────────────────────────────

ThemeData buildDarkTheme() => _buildTheme(
      brightness: Brightness.dark,
      colors: _dark,
      scaffold: const Color(0xFF1B1E28),
    );

ThemeData buildLightTheme() => _buildTheme(
      brightness: Brightness.light,
      colors: _light,
      scaffold: const Color(0xFFFFFFFF),
    );

ThemeData _buildTheme({
  required Brightness brightness,
  required AppColors colors,
  required Color scaffold,
}) {
  final base = ThemeData(
    brightness: brightness,
    scaffoldBackgroundColor: scaffold,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _NoTransitionBuilder(),
        TargetPlatform.iOS: _NoTransitionBuilder(),
        TargetPlatform.linux: _NoTransitionBuilder(),
        TargetPlatform.macOS: _NoTransitionBuilder(),
        TargetPlatform.windows: _NoTransitionBuilder(),
      },
    ),
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: colors.mostroGreen,
      onPrimary: Colors.white,
      secondary: colors.purpleButton,
      onSecondary: Colors.white,
      error: colors.destructiveRed,
      onError: Colors.white,
      surface: colors.backgroundCard,
      onSurface: colors.textPrimary,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scaffold,
      foregroundColor: colors.textPrimary,
      elevation: 0,
      iconTheme: IconThemeData(color: colors.textPrimary),
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: scaffold,
      selectedItemColor: colors.mostroGreen,
      unselectedItemColor: colors.textDisabled,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: colors.backgroundCard,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.backgroundInput,
      labelStyle: TextStyle(color: colors.textSecondary),
      hintStyle: TextStyle(color: colors.textSubtle),
      enabledBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: colors.textSubtle),
      ),
      focusedBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: colors.mostroGreen, width: 2),
      ),
    ),
    textTheme: TextTheme(
      displayLarge: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.bold,
        color: colors.textPrimary,
        height: 1.2,
      ),
      headlineLarge: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.bold,
        color: colors.textPrimary,
        height: 1.3,
      ),
      headlineMedium: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.bold,
        color: colors.textPrimary,
        height: 1.3,
      ),
      headlineSmall: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w500,
        color: colors.textPrimary,
        height: 1.4,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.normal,
        color: colors.textPrimary,
        height: 1.5,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.normal,
        color: colors.textSecondary,
        height: 1.5,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.normal,
        color: colors.textSubtle,
        height: 1.4,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: colors.textPrimary,
        height: 1.3,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: colors.textPrimary,
        height: 1.2,
      ),
    ),
    extensions: [colors],
  );
  return base;
}

// Instant page transition — no animation.
class _NoTransitionBuilder extends PageTransitionsBuilder {
  const _NoTransitionBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child;
}
