import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Intercepts the Android system back button on the brand kit screen
/// and exits the app immediately, without a confirmation dialog.
///
/// Why the brand kit is special:
///   * It is the root-of-stack destination after login (the AppBar back
///     arrow is intentionally hidden so a half-finished generation can't
///     be orphaned).
///   * The user has nowhere meaningful to navigate "back" to - the
///     welcome / business-info flow is finished.
///   * Showing a confirmation dialog ("Leave Tamiva? / Stay / Exit") on
///     every system back press feels heavy for a screen that's already
///     a terminal destination.
///
/// Behaviour:
///   * System back / gesture back → [SystemNavigator.pop()] (app exits).
///   * Other gestures, taps, scroll, and in-app nav (pushes like
///     PricingScreen / ArtifactsScreen) are unchanged.
///
/// On iOS this is inert - iOS apps don't quit programmatically per
/// platform guidelines (Apple explicitly disallows programmatic exit).
class ExitOnBackScope extends StatelessWidget {
  final Widget child;

  const ExitOnBackScope({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // canPop: false blocks the automatic pop so the first system back
      // press closes the app instead of navigating back to a route that
      // doesn't exist (or that we'd rather the user not return to).
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Close the app on Android. iOS ignores this per platform
        // guidelines (Apple explicitly disallows programmatic exit).
        SystemNavigator.pop();
      },
      child: child,
    );
  }
}
