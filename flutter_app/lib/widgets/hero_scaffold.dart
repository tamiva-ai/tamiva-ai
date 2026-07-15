import 'package:flutter/material.dart';
import '../theme/tamiva_theme.dart';

/// Full-bleed hero background with a scrim for legibility, used on the
/// welcome and login screens where the form is the entire screen.
///
/// [heroAsset] is expected under assets/hero/. These currently ship as
/// generated placeholder gradients — swap the PNG at the same path with
/// real AI-generated hero art (Midjourney / GPT Image) any time; no code
/// changes needed. If the asset is ever missing, this falls back to a
/// plain gradient so the app never crashes on a missing image.
class HeroScaffold extends StatelessWidget {
  final String heroAsset;
  final Widget child;
  final bool showBackButton;

  const HeroScaffold({
    super.key,
    required this.heroAsset,
    required this.child,
    this.showBackButton = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: showBackButton
          ? AppBar(backgroundColor: Colors.transparent, elevation: 0)
          : null,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            heroAsset,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const _FallbackGradient(),
          ),
          // Scrim: darker toward the bottom so form fields stay legible
          // over the art without flattening it entirely.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x00000000),
                  Color(0xB30A0A0D),
                  Color(0xF20A0A0D),
                ],
                stops: [0.0, 0.55, 1.0],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top +
                  (showBackButton ? kToolbarHeight : 0),
              bottom: MediaQuery.of(context).padding.bottom,
            ),
            child: child,
          ),
        ],
      ),
    );
  }
}

/// Shorter hero banner used at the top of content-heavy screens (business
/// info, ambassador photos, brand assets) where most of the screen is a
/// scrollable form or grid below the art.
class HeroBannerScaffold extends StatelessWidget {
  final String heroAsset;
  final String title;
  final Widget body;
  final Widget? bottomBar;
  final List<Widget>? actions;

  const HeroBannerScaffold({
    super.key,
    required this.heroAsset,
    required this.title,
    required this.body,
    this.bottomBar,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    // v37.1: deterministic back behavior. The SliverAppBar's default
    // `BackButton` (and the OS back gesture) both call
    // `Navigator.maybePop()`. If there is no route to pop, we fall
    // through to `SystemNavigator.pop()` so the app exits to the
    // launcher cleanly. This makes the in-app arrow and the OS back
    // gesture behave identically, and ensures a free user on the
    // root screen lands on the launcher instead of getting stuck.
    return PopScope(
      canPop: false, // we always handle pop ourselves for deterministic behavior
      onPopInvokedWithResult: (didPop, _) async {
        final navigator = Navigator.maybeOf(context);
        if (navigator == null) {
          // ignore: deprecated_member_use
          await SystemNavigator.pop();
          return;
        }
        final popped = await navigator.maybePop();
        if (!popped) {
          // No more routes — close the app to launcher.
          // ignore: deprecated_member_use
          await SystemNavigator.pop();
        }
      },
      child: Scaffold(
        bottomNavigationBar: bottomBar,
        body: CustomScrollView(
          slivers: [
            SliverAppBar(
              expandedHeight: 200,
              pinned: true,
              backgroundColor: TamivaColors.background,
              surfaceTintColor: Colors.transparent,
              // Back arrow is now always shown (no toggle). PopScope
              // above handles whether tapping it pops a route or
              // closes the app.
              actions: actions,
              flexibleSpace: FlexibleSpaceBar(
                centerTitle: true,
                titlePadding: const EdgeInsets.fromLTRB(56, 0, 56, 16),
                title: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                background: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.asset(
                      heroAsset,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const _FallbackGradient(),
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x000A0A0D),
                            Color(0xE60A0A0D),
                          ],
                          stops: [0.35, 1.0],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverSafeArea(
              top: false,
              sliver: SliverToBoxAdapter(child: body),
            ),
          ],
        ),
      ),
    );
  }
}

class _FallbackGradient extends StatelessWidget {
  const _FallbackGradient();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [TamivaColors.maroon, TamivaColors.background],
        ),
      ),
    );
  }
}
