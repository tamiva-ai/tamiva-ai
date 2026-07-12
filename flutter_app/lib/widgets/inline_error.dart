import 'package:flutter/material.dart';
import '../errors/user_facing_error.dart';
import '../theme/tamiva_theme.dart';

/// Compact inline error bubble suitable for placing above a submit
/// button. Softer than a snackbar, calmer than a dialog.
class InlineError extends StatelessWidget {
  final UserFacingError error;
  final VoidCallback? onRetry;

  const InlineError({
    super.key,
    required this.error,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TamivaColors.error.withOpacity(0.10),
        border: Border.all(color: TamivaColors.error.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(TamivaRadii.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: TamivaColors.error, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  error.title,
                  style: textTheme.titleMedium?.copyWith(
                    color: TamivaColors.error,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  error.message,
                  style: textTheme.bodyMedium?.copyWith(color: TamivaColors.textPrimary),
                ),
                if (error.hint != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    error.hint!,
                    style: textTheme.bodyMedium?.copyWith(
                      color: TamivaColors.textFaint,
                      fontSize: 12,
                    ),
                  ),
                ],
                if (onRetry != null && error.retryLabel != null) ...[
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: onRetry,
                    child: Text(
                      error.retryLabel!,
                      style: textTheme.labelLarge?.copyWith(
                        color: TamivaColors.gold,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Helper to show any UserFacingError as a snackbar with an optional
/// retry action. Suitable for background operations (uploads, polls).
void showErrorSnackbar(
  BuildContext context,
  UserFacingError error, {
  VoidCallback? onRetry,
}) {
  ScaffoldMessenger.of(context).clearSnackBars();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          const Icon(Icons.error_outline, color: TamivaColors.error, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(error.message)),
        ],
      ),
      duration: const Duration(seconds: 5),
      action: (onRetry != null && error.retryLabel != null)
          ? SnackBarAction(
              label: error.retryLabel!,
              textColor: TamivaColors.gold,
              onPressed: onRetry,
            )
          : null,
    ),
  );
}
