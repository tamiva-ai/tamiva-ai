/// Fixed list of colour palettes users can pick at signup time.
/// Max 2 selections, stored as CSV in BusinessProfile.palettePreference.
/// Each entry includes the hex codes the worker injects into logo /
/// carousel / film prompts (Creative Director template).
class PaletteStyle {
  final String key;
  final String displayName;
  final List<String> hexCodes;
  const PaletteStyle({required this.key, required this.displayName, required this.hexCodes});
}

class PaletteStyles {
  PaletteStyles._();

  static const warm = PaletteStyle(
    key: 'warm',
    displayName: 'Warm (maroon + ember + gold)',
    hexCodes: ['#8B1A2A', '#B85028', '#D4A72C'],
  );
  static const cool = PaletteStyle(
    key: 'cool',
    displayName: 'Cool (navy + teal + silver)',
    hexCodes: ['#0F2C44', '#1F8FAA', '#C0C0C0'],
  );
  static const monochrome = PaletteStyle(
    key: 'monochrome',
    displayName: 'Monochrome (black + gray + cream)',
    hexCodes: ['#1A1A1A', '#666666', '#FFF5E1'],
  );
  static const earthy = PaletteStyle(
    key: 'earthy',
    displayName: 'Earthy (brown + olive + tan)',
    hexCodes: ['#5C4033', '#708238', '#D2B48C'],
  );
  static const pastel = PaletteStyle(
    key: 'pastel',
    displayName: 'Pastel (soft pink + lavender + mint)',
    hexCodes: ['#FFB6C1', '#E6E6FA', '#98FF98'],
  );
  static const vibrant = PaletteStyle(
    key: 'vibrant',
    displayName: 'Vibrant (electric blue + magenta + yellow)',
    hexCodes: ['#7DF9FF', '#FF00FF', '#FFEA00'],
  );

  // ─── 15 additional palettes (added for v36 expansion) ────────────────

  static const jewelTones = PaletteStyle(
    key: 'jewel_tones',
    displayName: 'Jewel tones (emerald + sapphire + ruby)',
    hexCodes: ['#046A38', '#0F52BA', '#9B111E'],
  );
  static const sunset = PaletteStyle(
    key: 'sunset',
    displayName: 'Sunset (coral + peach + lavender)',
    hexCodes: ['#FF7F50', '#FFDAB9', '#E6E6FA'],
  );
  static const ocean = PaletteStyle(
    key: 'ocean',
    displayName: 'Ocean (deep blue + aqua + seafoam)',
    hexCodes: ['#003366', '#00CED1', '#93E9BE'],
  );
  static const forest = PaletteStyle(
    key: 'forest',
    displayName: 'Forest (pine + moss + fern)',
    hexCodes: ['#1B4D3E', '#606C38', '#8FBC8F'],
  );
  static const desert = PaletteStyle(
    key: 'desert',
    displayName: 'Desert (sand + terracotta + clay)',
    hexCodes: ['#C2B280', '#E2725B', '#A0522D'],
  );
  static const royal = PaletteStyle(
    key: 'royal',
    displayName: 'Royal (purple + gold + ivory)',
    hexCodes: ['#4B0082', '#FFD700', '#FFFFF0'],
  );
  static const minimalist = PaletteStyle(
    key: 'minimalist',
    displayName: 'Minimalist (white + charcoal + soft gray)',
    hexCodes: ['#FFFFFF', '#36454F', '#D3D3D3'],
  );
  static const neon = PaletteStyle(
    key: 'neon',
    displayName: 'Neon (lime + hot pink + cyan)',
    hexCodes: ['#CCFF00', '#FF1493', '#00FFFF'],
  );
  static const autumn = PaletteStyle(
    key: 'autumn',
    displayName: 'Autumn (burnt orange + mustard + crimson)',
    hexCodes: ['#CC5500', '#FFDB58', '#DC143C'],
  );
  static const winter = PaletteStyle(
    key: 'winter',
    displayName: 'Winter (ice blue + silver + white)',
    hexCodes: ['#AFDBF5', '#C0C0C0', '#FFFFFF'],
  );
  static const tropical = PaletteStyle(
    key: 'tropical',
    displayName: 'Tropical (turquoise + mango + fuchsia)',
    hexCodes: ['#40E0D0', '#FFC324', '#FF77FF'],
  );
  static const vintage = PaletteStyle(
    key: 'vintage',
    displayName: 'Vintage (mustard + teal + rust)',
    hexCodes: ['#FFDB58', '#008080', '#B7410E'],
  );
  static const muted = PaletteStyle(
    key: 'muted',
    displayName: 'Muted (sage + dusty rose + taupe)',
    hexCodes: ['#9CAF88', '#DCAE96', '#B38B6D'],
  );
  static const highContrast = PaletteStyle(
    key: 'high_contrast',
    displayName: 'High contrast (black + yellow + red)',
    hexCodes: ['#000000', '#FFD300', '#E10600'],
  );
  static const luxeGold = PaletteStyle(
    key: 'luxe_gold',
    displayName: 'Luxe gold (deep green + champagne + gold)',
    hexCodes: ['#014421', '#F7E7CE', '#D4AF37'],
  );

  /// The 21 options in the order shown in the form.
  static const List<PaletteStyle> all = [
    warm, cool, monochrome, earthy, pastel, vibrant,
    jewelTones, sunset, ocean, forest, desert, royal,
    minimalist, neon, autumn, winter, tropical, vintage,
    muted, highContrast, luxeGold,
  ];

  static PaletteStyle byKey(String key) =>
      all.firstWhere((p) => p.key == key, orElse: () => warm);

  /// Renders a CSV of palette names + their hex codes into a single
  /// string the prompts can consume. e.g. "Warm (#8B1A2A, #B85028,
  /// #D4A72C); Cool (#0F2C44, #1F8FAA, #C0C0C0)".
  static String describeCsv(String csv) {
    if (csv.isEmpty) return '';
    final keys = csv.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
    return keys
        .map((k) {
          final p = byKey(k);
          final hexes = p.hexCodes.join(', ');
          return '${p.displayName.split('(').first.trim()} ($hexes)';
        })
        .join('; ');
  }
}
