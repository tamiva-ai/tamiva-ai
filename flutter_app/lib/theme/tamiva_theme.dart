import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Tamiva's maroon-and-gold design tokens, drawn from the actual logo:
/// deep warm burgundy, antique gold accent, warm cream text. One place
/// to change the app's look; every screen inherits from here.
class TamivaColors {
  TamivaColors._();

  // Near-black warm burgundy - keeps the app feeling premium/cinematic
  // without ever going blue-cast or cold.
  static const background = Color(0xFF0F0507);
  static const surface = Color(0xFF1A0A0D);
  static const surfaceRaised = Color(0xFF241014);

  // Antique gold - the signature accent, matches the logo lotus/wordmark.
  static const gold = Color(0xFFD4A72C);
  static const goldBright = Color(0xFFE8C15C);
  static const goldMuted = Color(0xFF8A6E1F);

  // Maroon - the brand's core saturated hue, used for depth and gradients.
  static const maroon = Color(0xFF8B1A2A);
  static const maroonDeep = Color(0xFF5F1019);

  // Ember - warm burnt-orange highlight for gradients and CTAs.
  static const ember = Color(0xFFB85028);

  // Text sits on cream, not white - matches the logo's warmth.
  static const textPrimary = Color(0xFFFFF5E1);
  static const textSecondary = Color(0xFFC9B896);
  static const textFaint = Color(0xFF8A7C60);

  static const success = Color(0xFF7FB27C);
  static const error = Color(0xFFE0745C);

  static const divider = Color(0x33D4A72C); // gold @ 20%
}

class TamivaSpacing {
  TamivaSpacing._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
}

class TamivaRadii {
  TamivaRadii._();
  static const sm = 12.0;
  static const md = 18.0;
  static const lg = 24.0;
}

/// The gold-to-ember-to-maroon gradient used for the primary CTA. Its
/// role is the signature moment on every screen - use it only for the
/// hero call-to-action, never as a background wash.
const kTamivaCtaGradient = LinearGradient(
  begin: Alignment.centerLeft,
  end: Alignment.centerRight,
  colors: [
    TamivaColors.ember,
    TamivaColors.gold,
    TamivaColors.maroon,
  ],
  stops: [0.0, 0.5, 1.0],
);

class TamivaTheme {
  TamivaTheme._();

  /// Display face: Sora - geometric, playful, bold. Used for headlines
  /// and the wordmark eyebrow only.
  static TextStyle _display({
    required double size,
    FontWeight weight = FontWeight.w700,
    Color color = TamivaColors.textPrimary,
    double? height,
    double letterSpacing = -0.02,
  }) {
    return GoogleFonts.sora(
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: letterSpacing * size,
    );
  }

  /// Body/UI face: Manrope - clean, geometric, highly legible.
  static TextStyle _body({
    required double size,
    FontWeight weight = FontWeight.w400,
    Color color = TamivaColors.textPrimary,
    double? height,
    double letterSpacing = 0,
  }) {
    return GoogleFonts.manrope(
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  static ThemeData get dark {
    const colorScheme = ColorScheme.dark(
      brightness: Brightness.dark,
      primary: TamivaColors.gold,
      onPrimary: Color(0xFF1A0F02),
      secondary: TamivaColors.maroon,
      onSecondary: TamivaColors.textPrimary,
      surface: TamivaColors.surface,
      onSurface: TamivaColors.textPrimary,
      error: TamivaColors.error,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: TamivaColors.background,
      splashFactory: InkRipple.splashFactory,
      textTheme: TextTheme(
        displayLarge: _display(size: 42, weight: FontWeight.w700, height: 1.05),
        displayMedium: _display(size: 32, weight: FontWeight.w700, height: 1.1),
        headlineMedium: _display(size: 26, weight: FontWeight.w600, height: 1.2, letterSpacing: -0.01),
        titleLarge: _display(size: 20, weight: FontWeight.w600, height: 1.25, letterSpacing: -0.01),
        titleMedium: _body(size: 16, weight: FontWeight.w600, height: 1.3),
        bodyLarge: _body(size: 15, color: TamivaColors.textPrimary, height: 1.5),
        bodyMedium: _body(size: 13, color: TamivaColors.textSecondary, height: 1.5),
        labelLarge: _body(size: 14, weight: FontWeight.w600, letterSpacing: 0.2),
        labelMedium: _body(size: 11, weight: FontWeight.w600, color: TamivaColors.gold, letterSpacing: 3.0),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        iconTheme: const IconThemeData(color: TamivaColors.textPrimary),
        titleTextStyle: _body(size: 17, weight: FontWeight.w600),
      ),
      cardTheme: CardThemeData(
        color: TamivaColors.surfaceRaised,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TamivaRadii.md),
          side: const BorderSide(color: TamivaColors.divider),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0x1AD4A72C), // gold @ 10%
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        labelStyle: _body(size: 13, color: TamivaColors.textSecondary, weight: FontWeight.w600, letterSpacing: 1.2),
        floatingLabelStyle: _body(size: 12, color: TamivaColors.gold, weight: FontWeight.w700, letterSpacing: 1.5),
        hintStyle: _body(size: 14, color: TamivaColors.textFaint),
        helperStyle: _body(size: 11, color: TamivaColors.textFaint),
        errorStyle: _body(size: 12, color: TamivaColors.error),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TamivaRadii.sm),
          borderSide: const BorderSide(color: TamivaColors.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TamivaRadii.sm),
          borderSide: const BorderSide(color: TamivaColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TamivaRadii.sm),
          borderSide: const BorderSide(color: TamivaColors.gold, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TamivaRadii.sm),
          borderSide: const BorderSide(color: TamivaColors.error),
        ),
      ),
      // Note: for the hero CTA gradient we use the GradientCtaButton widget
      // instead of a solid FilledButton; secondary CTAs still use this.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: TamivaColors.gold,
          foregroundColor: const Color(0xFF1A0F02),
          disabledBackgroundColor: TamivaColors.goldMuted.withOpacity(0.4),
          padding: const EdgeInsets.symmetric(vertical: 15),
          textStyle: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 0.2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(TamivaRadii.sm),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: TamivaColors.textPrimary,
          side: const BorderSide(color: TamivaColors.divider),
          padding: const EdgeInsets.symmetric(vertical: 15),
          textStyle: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(TamivaRadii.sm),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: TamivaColors.gold,
          textStyle: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      dividerTheme: const DividerThemeData(color: TamivaColors.divider, thickness: 1),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: TamivaColors.gold),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: TamivaColors.surfaceRaised,
        contentTextStyle: _body(size: 14, color: TamivaColors.textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(TamivaRadii.sm)),
      ),
    );
  }
}

/// The signature gradient CTA button used for primary actions on hero
/// screens (welcome, login). It carries the gold-ember-maroon sweep so
/// the eye lands here.
class GradientCtaButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final bool loading;

  const GradientCtaButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: kTamivaCtaGradient,
          borderRadius: BorderRadius.circular(TamivaRadii.sm),
          boxShadow: [
            BoxShadow(
              color: TamivaColors.gold.withOpacity(0.28),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(TamivaRadii.sm),
          child: InkWell(
            onTap: enabled ? onPressed : null,
            borderRadius: BorderRadius.circular(TamivaRadii.sm),
            child: SizedBox(
              height: 52,
              width: double.infinity,
              child: Center(
                child: loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(Color(0xFF1A0F02)),
                        ),
                      )
                    : DefaultTextStyle(
                        style: GoogleFonts.sora(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF1A0F02),
                          letterSpacing: 0.3,
                        ),
                        child: child,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small capability chip used on the welcome dashboard to show what
/// Tamiva actually does before signup.
class CapabilityChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color tint;

  const CapabilityChip({
    super.key,
    required this.icon,
    required this.label,
    required this.tint,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: tint.withOpacity(0.14),
        border: Border.all(color: tint.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: tint),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.manrope(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: tint,
            ),
          ),
        ],
      ),
    );
  }
}
