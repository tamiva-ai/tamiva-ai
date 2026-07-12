import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/tamiva_theme.dart';

/// Intercepts Android back button presses at root-of-nav-stack screens
/// and asks the user to confirm before closing the app.
///
/// Only wrap this around screens that could be the last one on the
/// navigation stack (welcome, home). For deeper screens the system
/// back gesture should just pop normally - do NOT wrap those.
///
/// On iOS this is inert - iOS apps don't quit programmatically per
/// platform guidelines.
class ExitConfirmScope extends StatelessWidget {
  final Widget child;

  const ExitConfirmScope({super.key, required this.child});

  Future<void> _handleBack(BuildContext context) async {
    final textTheme = Theme.of(context).textTheme;
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: TamivaColors.surfaceRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TamivaRadii.md),
        ),
        title: Text('Leave Tamiva?', style: textTheme.titleLarge),
        content: Text(
          "Your progress is saved. You can pick up right where you left off next time.",
          style: textTheme.bodyMedium?.copyWith(color: TamivaColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Stay'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: TamivaColors.error,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Exit'),
          ),
        ],
      ),
    );

    if (shouldExit == true) {
      // Actually close the app on Android. iOS ignores this per platform
      // guidelines (Apple explicitly disallows programmatic exit).
      await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // canPop: false blocks the automatic pop so we can show the dialog
      // first and only exit if the user confirms.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBack(context);
      },
      child: child,
    );
  }
}
