import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lottie/lottie.dart';
import '../theme/tamiva_theme.dart';

/// A polished long-wait progress visual. Used for operations that take
/// 10+ seconds where a plain spinner would feel dead - logo generation,
/// carousel rendering, brand film assembly.
///
/// Renders a Lottie animation from [lottieAsset] if the asset exists in
/// the bundle, otherwise falls back to a hand-coded procedural
/// animation that reads as on-brand. Users can drop real Lottie files
/// into assets/lottie/ later without a code change.
///
/// [messages] rotates every 3s. The first entry is shown immediately;
/// subsequent entries make the wait feel like progress rather than a
/// hang.
class ProgressStatus extends StatefulWidget {
  final String lottieAsset;
  final String title;
  final List<String> messages;
  final Duration? estimatedDuration;

  const ProgressStatus({
    super.key,
    required this.lottieAsset,
    required this.title,
    required this.messages,
    this.estimatedDuration,
  });

  @override
  State<ProgressStatus> createState() => _ProgressStatusState();
}

class _ProgressStatusState extends State<ProgressStatus> {
  Timer? _messageTimer;
  int _messageIndex = 0;
  bool _lottieAvailable = true;

  @override
  void initState() {
    super.initState();
    _startMessageRotation();
    _checkLottieAsset();
  }

  Future<void> _checkLottieAsset() async {
    // Probe whether the Lottie asset is bundled. If not, we render the
    // procedural fallback silently rather than crashing.
    try {
      await rootBundle.load(widget.lottieAsset);
    } catch (_) {
      if (mounted) setState(() => _lottieAvailable = false);
    }
  }

  void _startMessageRotation() {
    if (widget.messages.length <= 1) return;
    _messageTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      setState(() {
        _messageIndex = (_messageIndex + 1) % widget.messages.length;
      });
    });
  }

  @override
  void dispose() {
    _messageTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 160,
            width: 160,
            child: _lottieAvailable
                ? Lottie.asset(
                    widget.lottieAsset,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const _ProceduralPulse(),
                  )
                : const _ProceduralPulse(),
          ),
          const SizedBox(height: 32),
          Text(
            widget.title,
            textAlign: TextAlign.center,
            style: textTheme.headlineMedium,
          ),
          const SizedBox(height: 12),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            child: Text(
              widget.messages[_messageIndex],
              key: ValueKey(_messageIndex),
              textAlign: TextAlign.center,
              style: textTheme.bodyLarge?.copyWith(color: TamivaColors.textSecondary),
            ),
          ),
          if (widget.estimatedDuration != null) ...[
            const SizedBox(height: 16),
            Text(
              _formatEta(widget.estimatedDuration!),
              textAlign: TextAlign.center,
              style: textTheme.labelMedium,
            ),
          ],
        ],
      ),
    );
  }

  String _formatEta(Duration d) {
    if (d.inSeconds < 60) return '~${d.inSeconds}S LEFT';
    final min = (d.inSeconds / 60).round();
    return min == 1 ? '~1 MINUTE LEFT' : '~$min MINUTES LEFT';
  }
}

/// Fallback animation when no Lottie file is provided. Three golden
/// orbs orbiting a warm center - reads as "the brand is being crafted"
/// without needing external assets. Keeps 60fps easily.
class _ProceduralPulse extends StatefulWidget {
  const _ProceduralPulse();

  @override
  State<_ProceduralPulse> createState() => _ProceduralPulseState();
}

class _ProceduralPulseState extends State<_ProceduralPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return CustomPaint(
          painter: _OrbitPainter(_controller.value),
          size: const Size(160, 160),
        );
      },
    );
  }
}

class _OrbitPainter extends CustomPainter {
  final double progress;
  _OrbitPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final orbitRadius = size.width * 0.32;

    // Warm central glow
    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          TamivaColors.gold.withOpacity(0.35),
          TamivaColors.gold.withOpacity(0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: size.width / 2));
    canvas.drawCircle(center, size.width / 2, glowPaint);

    // Three orbs, evenly spaced around the orbit
    for (int i = 0; i < 3; i++) {
      final phase = (progress + i / 3) % 1.0;
      final angle = phase * 2 * pi;
      final orbCenter = Offset(
        center.dx + orbitRadius * cos(angle),
        center.dy + orbitRadius * sin(angle),
      );
      final size = 10.0 + 4 * sin(phase * 2 * pi);
      final colors = [TamivaColors.gold, TamivaColors.ember, TamivaColors.maroon];
      final paint = Paint()..color = colors[i];
      // Soft glow around each orb
      canvas.drawCircle(orbCenter, size * 2.4, Paint()
        ..color = colors[i].withOpacity(0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
      canvas.drawCircle(orbCenter, size, paint);
    }
  }

  @override
  bool shouldRepaint(_OrbitPainter oldDelegate) => true;
}
