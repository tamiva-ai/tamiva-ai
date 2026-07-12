/// Fixed list of 6 font pair categories the user picks at signup time.
/// Max 2 selections, stored as CSV in BusinessProfile.fontPreference.
/// Display names are category-only ("Modern default", "Editorial", ...);
/// the underlying Google Font families are kept here for the UI preview
/// cards but NOT exposed in the prompt string.
class FontPair {
  final String key;
  final String displayName;
  final String googleFamily;
  final String description;
  const FontPair({
    required this.key,
    required this.displayName,
    required this.googleFamily,
    required this.description,
  });
}

class FontPairs {
  FontPairs._();

  static const modernDefault = FontPair(
    key: 'modern_default',
    displayName: 'Modern default',
    googleFamily: 'Manrope',
    description: 'Sora headlines + Manrope body. Clean geometric, contemporary.',
  );
  static const editorial = FontPair(
    key: 'editorial',
    displayName: 'Editorial',
    googleFamily: 'Playfair Display',
    description: 'Playfair Display headlines + Inter body. Premium magazine feel.',
  );
  static const techForward = FontPair(
    key: 'tech_forward',
    displayName: 'Tech-forward',
    googleFamily: 'Space Grotesk',
    description: 'Space Grotesk headlines + Inter body. Modern SaaS / hardware.',
  );
  static const elegantSerif = FontPair(
    key: 'elegant_serif',
    displayName: 'Elegant serif',
    googleFamily: 'DM Serif Display',
    description: 'DM Serif Display headlines + DM Sans body. Heritage / editorial.',
  );
  static const utility = FontPair(
    key: 'utility',
    displayName: 'Utility',
    googleFamily: 'Archivo',
    description: 'Archivo headlines + Source Sans 3 body. Clear, functional.',
  );
  static const boldDisplay = FontPair(
    key: 'bold_display',
    displayName: 'Bold display',
    googleFamily: 'Bebas Neue',
    description: 'Bebas Neue headlines + Roboto body. Punchy, attention-grabbing.',
  );

  /// The 6 options in the order shown in the form.
  static const List<FontPair> all = [
    modernDefault, editorial, techForward, elegantSerif, utility, boldDisplay,
  ];

  static FontPair byKey(String key) =>
      all.firstWhere((p) => p.key == key, orElse: () => modernDefault);

  /// CSV → "Modern default; Editorial" prompt fragment.
  static String describeCsv(String csv) {
    if (csv.isEmpty) return '';
    final keys = csv.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
    return keys.map((k) => byKey(k).displayName).join('; ');
  }
}
