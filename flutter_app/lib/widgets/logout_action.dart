import 'package:flutter/material.dart';
import '../services/api_client.dart';
import '../theme/tamiva_theme.dart';
import '../screens/welcome_screen.dart';

/// Logout icon suitable for placing in an AppBar's actions list. Shows
/// a confirmation dialog, then returns the user to the welcome screen
/// with the entire nav stack cleared.
///
/// The session model is currently "userId held in memory" (no JWT yet),
/// so signing out just means popping back to the entry point.
class LogoutAction extends StatelessWidget {
  final ApiClient apiClient;

  const LogoutAction({super.key, required this.apiClient});

  Future<void> _confirmAndSignOut(BuildContext context) async {
    final textTheme = Theme.of(context).textTheme;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: TamivaColors.surfaceRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TamivaRadii.md),
        ),
        title: Text('Sign out?', style: textTheme.titleLarge),
        content: Text(
          "You'll come back to the welcome screen. Your studio and drafts stay saved.",
          style: textTheme.bodyMedium?.copyWith(color: TamivaColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: TamivaColors.error,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!context.mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => WelcomeScreen(apiClient: apiClient)),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Sign out',
      icon: const Icon(Icons.logout, color: TamivaColors.textPrimary),
      onPressed: () => _confirmAndSignOut(context),
    );
  }
}
