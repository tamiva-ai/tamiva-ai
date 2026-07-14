/// v37: Pricing plans for Tamiva. The three tiers (Launch / Business /
/// Premium) each map to a server-side tier value (`launch` / `pro` /
/// `premium`) and a Razorpay order amount.
///
/// Hardcoded on the client because plan copy / pricing rarely changes.
/// If a future plan is added, the server's `PLAN_AMOUNTS_PAISE` lookup
/// table (in `routes/payments.ts`) is the source of truth — extend both
/// in lockstep.
class PricingPlan {
  /// Server-side tier id, stored on `User.tier`.
  final String id;

  /// Display name shown on the Pricing screen.
  final String name;

  /// Short subtitle (one line).
  final String tagline;

  /// Price in paise (₹1 = 100 paise). Mirrors server's
  /// `PLAN_AMOUNTS_PAISE`.
  final int amountPaise;

  /// Display price as `₹X,XXX`.
  String get priceDisplay {
    final rupees = amountPaise ~/ 100;
    final s = rupees.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buffer.write(',');
      buffer.write(s[i]);
    }
    return '₹$buffer';
  }

  /// Bullet-list features shown beneath the price. Keep short.
  final List<String> features;

  const PricingPlan({
    required this.id,
    required this.name,
    required this.tagline,
    required this.amountPaise,
    required this.features,
  });
}

class PricingPlans {
  PricingPlans._();

  static const launch = PricingPlan(
    id: 'launch',
    name: 'Launch',
    tagline: 'Everything to put your brand online.',
    amountPaise: 199900,
    features: [
      '3 Logo Concepts',
      '2 Social Media Carousels',
      '1 AI Brand Film (15 sec)',
      '1-Page AI Website',
      'Brand Kit, AI Website Content & SEO',
      'HD Downloads',
    ],
  );

  static const business = PricingPlan(
    id: 'pro',
    name: 'Business',
    tagline: 'For growing brands ready to scale.',
    amountPaise: 599900,
    features: [
      '5 Logo Concepts',
      '10 Social Media Carousels',
      '3 AI Brand Films (15 sec each)',
      '5-Page AI Website',
      'Brand Kit, AI Website Content & SEO',
      'HD Downloads',
    ],
  );

  static const premium = PricingPlan(
    id: 'premium',
    name: 'Premium',
    tagline: 'The full studio, end to end.',
    amountPaise: 999900,
    features: [
      '10 Logo Concepts',
      '15 Social Media Carousels',
      '5 AI Brand Films (15 sec each)',
      '10-Page AI Website',
      'Brand Kit, AI Website Content & SEO',
      'HD Downloads',
      'Domain & SSL Setup',
    ],
  );

  static const List<PricingPlan> all = [launch, business, premium];

  static PricingPlan byId(String id) =>
      all.firstWhere((p) => p.id == id, orElse: () => business);
}