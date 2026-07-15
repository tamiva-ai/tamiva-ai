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

  /// v37.1: opt-out flag for the automatic back button. `SliverAppBar`
  /// shows a back arrow whenever there is a route to pop. Set this to
  /// `false` on screens where leaving mid-flow would lose work or
  /// orphan a server-side generation (e.g. the brand kit screen
  /// while a logo/carousel/film is generating).
  final bool showBackButton;

  const HeroBannerScaffold({
    super.key,
    required this.heroAsset,
    required this.title,
    required this.body,
    this.bottomBar,
    this.actions,
    this.showBackButton = true,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: bottomBar,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            backgroundColor: TamivaColors.background,
            surfaceTintColor: Colors.transparent,
            automaticallyImplyLeading: showBackButton,
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
