/// Fixed list of font pair categories the user picks at signup time.
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

  // ─── 15 additional font pairs (added for v36 expansion) ──────────────

  static const classicSerif = FontPair(
    key: 'classic_serif',
    displayName: 'Classic serif',
    googleFamily: 'Lora',
    description: 'Lora headlines + Lora body. Warm, literary, story-led brands.',
  );
  static const condensed = FontPair(
    key: 'condensed',
    displayName: 'Condensed',
    googleFamily: 'Oswald',
    description: 'Oswald headlines + Open Sans body. Strong verticals, posters.',
  );
  static const handwritten = FontPair(
    key: 'handwritten',
    displayName: 'Handwritten',
    googleFamily: 'Caveat',
    description: 'Caveat headlines + Quicksand body. Friendly, artisanal tone.',
  );
  static const retro = FontPair(
    key: 'retro',
    displayName: 'Retro',
    googleFamily: 'Abril Fatface',
    description: 'Abril Fatface headlines + Lato body. Vintage display energy.',
  );
  static const corporate = FontPair(
    key: 'corporate',
    displayName: 'Corporate',
    googleFamily: 'Poppins',
    description: 'Poppins headlines + Poppins body. Reliable SaaS / enterprise.',
  );
  static const brutalist = FontPair(
    key: 'brutalist',
    displayName: 'Brutalist',
    googleFamily: 'Space Mono',
    description: 'Space Mono headlines + IBM Plex Sans body. Stark, opinionated.',
  );
  static const geometric = FontPair(
    key: 'geometric',
    displayName: 'Geometric',
    googleFamily: 'Montserrat',
    description: 'Montserrat headlines + Montserrat body. Pure circles and squares.',
  );
  static const humanist = FontPair(
    key: 'humanist',
    displayName: 'Humanist',
    googleFamily: 'Nunito',
    description: 'Nunito headlines + Nunito body. Warm, rounded, approachable.',
  );
  static const luxury = FontPair(
    key: 'luxury',
    displayName: 'Luxury',
    googleFamily: 'Cormorant Garamond',
    description: 'Cormorant Garamond headlines + Raleway body. Couture / hospitality.',
  );
  static const sports = FontPair(
    key: 'sports',
    displayName: 'Sports',
    googleFamily: 'Anton',
    description: 'Anton headlines + Roboto Condensed body. Athletic, high-energy.',
  );
  static const educational = FontPair(
    key: 'educational',
    displayName: 'Educational',
    googleFamily: 'Merriweather',
    description: 'Merriweather headlines + Open Sans body. Long-form readability.',
  );
  static const playful = FontPair(
    key: 'playful',
    displayName: 'Playful',
    googleFamily: 'Fredoka',
    description: 'Fredoka headlines + Nunito body. Kids, toys, joyful products.',
  );
  static const minimalMono = FontPair(
    key: 'minimal_mono',
    displayName: 'Minimal mono',
    googleFamily: 'JetBrains Mono',
    description: 'JetBrains Mono headlines + Inter body. Developer / tooling brands.',
  );
  static const swiss = FontPair(
    key: 'swiss',
    displayName: 'Swiss',
    googleFamily: 'Work Sans',
    description: 'Work Sans headlines + Work Sans body. Neutral grid-driven clarity.',
  );
  static const script = FontPair(
    key: 'script',
    displayName: 'Script',
    googleFamily: 'Dancing Script',
    description: 'Dancing Script headlines + Inter body. Boutique / lifestyle warmth.',
  );

  /// The 21 options in the order shown in the form.
  static const List<FontPair> all = [
    modernDefault, editorial, techForward, elegantSerif, utility, boldDisplay,
    classicSerif, condensed, handwritten, retro, corporate,
    brutalist, geometric, humanist, luxury, sports,
    educational, playful, minimalMono, swiss, script,
  ];

  /// Look up a font pair by its [key]. Tolerates legacy displayName strings
  /// (e.g. "Editorial") so older saved BusinessProfiles load cleanly.
  static FontPair byKey(String keyOrDisplayName) =>
      all.firstWhere(
        (p) => p.key == keyOrDisplayName || p.displayName == keyOrDisplayName,
        orElse: () => modernDefault,
      );

  /// CSV → "Modern default; Editorial" prompt fragment.
  static String describeCsv(String csv) {
    if (csv.isEmpty) return '';
    final keys = csv.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
    return keys.map((k) => byKey(k).displayName).join('; ');
  }
}
