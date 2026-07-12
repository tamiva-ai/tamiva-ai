import 'package:flutter/material.dart';
import '../errors/user_facing_error.dart';
import '../theme/tamiva_theme.dart';

/// Full-screen retry card. Use when the user is completely stuck - the
/// backend is unreachable, or something they need to proceed didn't
/// arrive. Not for form errors (use InlineError) or background failures
/// (use showErrorSnackbar).
class FullScreenError extends StatelessWidget {
  final UserFacingError error;
  final VoidCallback? onRetry;
  final VoidCallback? onGoBack;

  const FullScreenError({
    super.key,
    required this.error,
    this.onRetry,
    this.onGoBack,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: TamivaColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.cloud_off_outlined,
                size: 56,
                color: TamivaColors.gold,
              ),
              const SizedBox(height: 24),
              Text(
                error.title,
                textAlign: TextAlign.center,
                style: textTheme.displayMedium,
              ),
              const SizedBox(height: 12),
              Text(
                error.message,
                textAlign: TextAlign.center,
                style: textTheme.bodyLarge?.copyWith(color: TamivaColors.textSecondary),
              ),
              if (error.hint != null) ...[
                const SizedBox(height: 8),
                Text(
                  error.hint!,
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium?.copyWith(color: TamivaColors.textFaint),
                ),
              ],
              const SizedBox(height: 32),
              if (onRetry != null)
                GradientCtaButton(
                  onPressed: onRetry,
                  child: Text(error.retryLabel ?? 'Try again'),
                ),
              if (onGoBack != null) ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: onGoBack,
                  child: const Text('Go back'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
