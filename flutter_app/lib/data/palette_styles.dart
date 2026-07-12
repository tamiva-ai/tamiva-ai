/// Fixed list of 6 color palettes users can pick at signup time.
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

  /// The 6 options in the order shown in the form.
  static const List<PaletteStyle> all = [warm, cool, monochrome, earthy, pastel, vibrant];

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
