import 'package:flutter/material.dart';
import '../theme/tamiva_theme.dart';

/// A stack of "cards" showing that there are variants available - front
/// card is sharp and clickable, back cards fan out with rotation and
/// dimming to signal there are more locked behind Pro.
///
/// Pass [frontChild] for the visible/free asset. [hiddenCount] is the
/// number of Pro-locked variants; only up to 3 are drawn as visible
/// stacked cards, but the "+N more" pill reflects the true count.
class CascadedStack extends StatelessWidget {
  final Widget frontChild;
  final int hiddenCount;
  final double height;
  final VoidCallback? onFrontTap;
  final VoidCallback? onLockedTap;

  /// Toggle the gold "Free" pill in the top-left of the front card.
  /// Defaults to true (every tile shows it). Set to false on tiles
  /// whose content is fully Pro-locked (e.g. the Website tile) where
  /// the "Free" pill would be misleading.
  final bool showFreePill;

  const CascadedStack({
    super.key,
    required this.frontChild,
    required this.hiddenCount,
    this.height = 180,
    this.onFrontTap,
    this.onLockedTap,
    this.showFreePill = true,
  });

  @override
  Widget build(BuildContext context) {
    // Show at most 3 stacked back-cards for visual effect. Their exact
    // count doesn't need to match hiddenCount - the "+N more" pill does.
    final visibleStackDepth = hiddenCount.clamp(0, 3);

    return SizedBox(
      height: height,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          // Back stack (locked variants) - drawn back-to-front so front
          // card sits on top.
          for (int i = visibleStackDepth; i >= 1; i--)
            _StackedBackCard(
              depth: i,
              maxDepth: visibleStackDepth,
              onTap: onLockedTap,
            ),

          // Front card - the actual visible asset
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            bottom: 0,
            child: Padding(
              // Slight inset so back cards peek from behind
              padding: EdgeInsets.only(
                left: visibleStackDepth > 0 ? 8 : 0,
                right: visibleStackDepth > 0 ? 8 : 0,
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(TamivaRadii.md),
                child: InkWell(
                  onTap: onFrontTap,
                  borderRadius: BorderRadius.circular(TamivaRadii.md),
                  child: Container(
                    decoration: BoxDecoration(
                      color: TamivaColors.surface,
                      border: Border.all(color: TamivaColors.gold, width: 1.2),
                      borderRadius: BorderRadius.circular(TamivaRadii.md),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.4),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(TamivaRadii.md - 1),
                            child: frontChild,
                          ),
                        ),
                        // "Free" pill (top-left) — hidden on fully
                        // Pro-locked tiles (e.g. the Website tile).
                        if (showFreePill)
                          Positioned(
                            left: 10,
                            top: 10,
                            child: _Pill(
                              label: 'Free',
                              background: TamivaColors.gold,
                              foreground: const Color(0xFF1A0F02),
                            ),
                          ),
                        // "+N more" pill (top-right) when there are hidden variants
                        if (hiddenCount > 0)
                          Positioned(
                            right: 10,
                            top: 10,
                            child: _Pill(
                              label: 'Pro · +$hiddenCount more',
                              background: Colors.black.withOpacity(0.55),
                              foreground: TamivaColors.gold,
                              borderColor: TamivaColors.gold,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StackedBackCard extends StatelessWidget {
  final int depth;
  final int maxDepth;
  final VoidCallback? onTap;

  const _StackedBackCard({
    required this.depth,
    required this.maxDepth,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Fan-out: alternate rotation direction so cards spread on both sides
    final rotation = (depth.isOdd ? -1 : 1) * 0.025 * depth;
    final horizontalOffset = depth * 12.0;
    final opacityFactor = 1 - (depth * 0.25);

    return Positioned(
      left: horizontalOffset,
      right: horizontalOffset,
      top: 6.0 * depth,
      bottom: -4.0 * depth,
      child: Transform.rotate(
        angle: rotation,
        child: Opacity(
          opacity: opacityFactor.clamp(0.15, 1.0),
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              decoration: BoxDecoration(
                color: TamivaColors.surfaceRaised,
                border: Border.all(color: TamivaColors.divider),
                borderRadius: BorderRadius.circular(TamivaRadii.md),
              ),
              child: const Center(
                child: Icon(Icons.lock_outline, size: 20, color: TamivaColors.gold),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color background;
  final Color foreground;
  final Color? borderColor;

  const _Pill({
    required this.label,
    required this.background,
    required this.foreground,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric