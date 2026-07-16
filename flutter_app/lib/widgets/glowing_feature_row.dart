import 'package:flutter/material.dart';
import '../theme/tamiva_theme.dart';

/// A feature row that draws the eye with a soft, ever-so-slight
/// pulsing gold glow. Use for the headline feature on the Pricing
/// screen (the "AI Website" line in Business/Premium) so the
/// reader's gaze lands on what's new and unlockable.
///
/// Why a gentle pulse and not a constant glow: a constant glow is
/// visually loud and gets ignored after the first second; a slow
/// 1.6s ease-in/out alpha sweep registers as "alive" but never
/// competes with the page's read price.
class GlowingFeatureRow extends StatefulWidget {
  final String text;
  final IconData icon;

  const GlowingFeatureRow({
    super.key,
    required this.text,
    this.icon = Icons.check,
  });

  @override
  State<GlowingFeatureRow> createState() => _GlowingFeatureRowState();
}

class _GlowingFeatureRowState extends State<GlowingFeatureRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      // 1.6s gives the eye time to track the change without flicker.
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The pulse: 0.45 -> 0.85 alpha on a soft 24px box shadow ring.
    // We keep the icon and text solid gold at all times; only the
    // outer glow breathes.
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) {
        final t = Curves.easeInOut.transform(_controller.value);
        final glowAlpha = 0.45 + (0.40 * t); // 0.45..0.85
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            // Inner tint that pulses gently with the glow. Subtle enough
            // to never compete with the price text above it.
            color: TamivaColors.gold.withOpacity(0.06 + (0.06 * t)),
            border: Border.all(
              color: TamivaColors.gold.withOpacity(glowAlpha * 0.55),
            ),
            boxShadow: [
              BoxShadow(
                color: TamivaColors.gold.withOpacity(0.20 * glowAlpha),
                blurRadius: 18,
                spreadRadius: 0.5,
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 14, color: TamivaColors.gold),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.text,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: TamivaColors.gold,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
