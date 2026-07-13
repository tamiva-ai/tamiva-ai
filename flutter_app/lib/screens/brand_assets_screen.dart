import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../errors/user_facing_error.dart';
import '../services/api_client.dart';
import '../services/asset_saver.dart';
import '../services/payment_service.dart';
import '../widgets/net_image.dart';
import '../models/models.dart';
import '../data/palette_styles.dart';
import '../data/font_pairs.dart';
import '../theme/tamiva_theme.dart';
import '../widgets/cascaded_stack.dart';
import '../widgets/full_screen_error.dart';
import '../widgets/hero_scaffold.dart';
import '../widgets/logout_action.dart';
import '../widgets/generation_status_board.dart';

/// Routes to the right full-screen viewer for a finished Project,
/// based on its [Project.type]. When the project isn't ready or has no
/// assets yet, surfaces a SnackBar with the reason rather than failing
/// silently - the silent version masked real bugs (assets missing,
/// status out of sync).
Future<void> openProjectPreview(
  BuildContext context,
  ApiClient apiClient,
  Project project,
) async {
  if (!project.isReady) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          project.isFailed
              ? 'Generation failed. Pull to retry.'
              : 'Still generating - try again in a moment.',
        ),
      ),
    );
    return;
  }
  if (project.assets.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Ready but no assets yet - try again in a moment.'),
      ),
    );
    return;
  }

  switch (project.type) {
    case 'logo':
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _LogoViewerScreen(assets: project.assets),
        ),
      );
      return;
    case 'carousel':
      final sorted = (project.assets.toList()
        ..sort((a, b) => (a.slideIndex ?? 0).compareTo(b.slideIndex ?? 0)));
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _CarouselViewerScreen(assets: sorted),
        ),
      );
      return;
    case 'video':
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _FilmViewerScreen(asset: project.assets.first),
        ),
      );
      return;
    default:
      return;
  }
}


/// Saves an image asset (data: URL or http(s) URL) to the device
/// gallery, showing progress + result feedback via SnackBars.
Future<void> _downloadImageAsset(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    const SnackBar(
      content: Text('Saving to your gallery…'),
      duration: Duration(seconds: 1),
    ),
  );
  final result = await saveImageToGallery(url);
  if (!context.mounted) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(result.ok ? 'Saved to your gallery.' : result.error!),
    ),
  );
}

/// Opens a video/film asset URL in the device browser, where it can be
/// played or downloaded. In-app playback lands in a later milestone.
Future<void> _openAssetInBrowser(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  final launched = uri != null &&
      await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!context.mounted || launched) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text("Couldn't open the film. Try again in a moment.")),
  );
}

/// The "brand kit" reveal screen. Kicks off logo generation on load,
/// polls for status, and displays five brand-kit sections.
///
/// Three sections now have live generation behind the front tile:
///
///   * Logo     - kicks off automatically on screen load (existing flow)
///   * Carousel - tap front card, confirm cost, then we render 5 slides
///   * Film     - tap front card, confirm cost, then we render 8s video
///
/// Colors and Typography remain visual previews; wiring them is out of
/// scope for this milestone.
class BrandAssetsScreen extends StatefulWidget {
  final ApiClient apiClient;
  final String businessProfileId;

  const BrandAssetsScreen({
    super.key,
    required this.apiClient,
    required this.businessProfileId,
  });

  @override
  State<BrandAssetsScreen> createState() => _BrandAssetsScreenState();
}

class _BrandAssetsScreenState extends State<BrandAssetsScreen> {
  String? _projectId;
  Project? _project;
  // v24: business profile snapshot, used to render the read-only palette +
  // font preference preview cards at the top of the reveal view.
  BusinessProfile? _profile;
  Timer? _pollTimer;
  UserFacingError? _error;

  // True while we check the backend for an existing logo on load, so we
  // don't flash the "Generate your logo" CTA before we know the state.
  bool _bootstrapping = true;
  // True while a manual logo generation request is in flight, for the
  // CTA button's loading state.
  bool _startingLogo = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _bootstrapLogo();
  }

  /// On load, adopt any logo the user already has instead of blindly
  /// firing a new generation on every mount (which is what spawned
  /// duplicate logos). If a logo exists we resume/show it; if it's
  /// still running we start polling; if none exists we fall through to
  /// a manual "Generate your logo" CTA and wait for the user to tap it.
  Future<void> _bootstrapLogo() async {
    try {
      final projects = await widget.apiClient
          .getBusinessProfileProjects(widget.businessProfileId);
      final logo = projects.logo;
      if (!mounted) return;
      if (logo != null) {
        setState(() {
          _projectId = logo.id;
          _project = logo;
          _bootstrapping = false;
        });
        if (logo.isInProgress) {
          _pollTimer =
              Timer.periodic(const Duration(seconds: 3), (_) => _poll());
        }
        return;
      }
    } catch (_) {
      // Non-fatal: fall through to the manual CTA so the user can start.
    }
    if (mounted) setState(() => _bootstrapping = false);
  }

  Future<void> _loadProfile() async {
    try {
      final profile = await widget.apiClient.getBusinessProfileById(widget.businessProfileId);
      if (!mounted) return;
      setState(() => _profile = profile);
    } catch (_) {
      // Non-fatal - hide the preference cards if the lookup fails.
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  /// Manually starts logo generation (from the CTA, a failed-row retry,
  /// or the error-screen retry). Guards against double-fire and wires
  /// the new project into this screen's own polling so the reveal
  /// triggers when the logo lands.
  Future<void> _beginLogoGeneration() async {
    if (_startingLogo) return;
    setState(() {
      _startingLogo = true;
      _error = null;
    });
    try {
      final projectId = await widget.apiClient.createLogoProject(
        businessProfileId: widget.businessProfileId,
        stylePrompt: 'clean, modern, minimal geometric mark',
      );
      if (!mounted) return;
      setState(() {
        _projectId = projectId;
        _startingLogo = false;
      });
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _startingLogo = false;
        _error = UserFacingError.from(e, operation: 'start generation');
      });
    }
  }

  Future<void> _poll() async {
    if (_projectId == null) return;
    try {
      final project = await widget.apiClient.getProject(_projectId!);
      setState(() => _project = project);
      if (project.isReady || project.isFailed) {
        _pollTimer?.cancel();
      }
    } catch (_) {
      // transient - retry on next tick
    }
  }

  void _showComingSoon() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Included in Tamiva Pro — tap Upgrade to unlock.'),
      ),
    );
  }

  Future<void> _startProCheckout() async {
    final result = await PaymentService.startProCheckout(
      api: widget.apiClient,
      businessProfileId: widget.businessProfileId,
    );
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (result.ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text("You're now on Tamiva Pro.")),
      );
    } else if (result.cancelled) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Checkout cancelled.')),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text(result.message ?? 'Checkout failed.')),
      );
    }
  }

  /// Centralized handler for taps on the GenerationStatusBoard rows.
  /// Dispatches based on [artifactKey] and current [project] state.
  Future<void> _handleStatusBoardTap(String artifactKey, Project? project) async {
    switch (artifactKey) {
      case 'logo':
        // Tapping a ready row opens the preview; a not-started or failed
        // row (re)starts generation via the parent so this screen's own
        // polling picks it up and reveals the kit when it lands.
        if (project != null && project.isReady) {
          await openProjectPreview(context, widget.apiClient, project);
        } else if (project == null || project.isFailed) {
          await _beginLogoGeneration();
        }
        return;
      case 'colors':
        await _showStaticPreview(
          context,
          title: 'Signature palette',
          body: _ColorsDetailBody(profile: _profile),
        );
        return;
      case 'typography':
        await _showStaticPreview(
          context,
          title: 'Type system',
          body: _TypographyDetailBody(profile: _profile),
        );
        return;
      case 'carousel':
        if (project != null && project.isReady) {
          await openProjectPreview(context, widget.apiClient, project);
        } else if (project != null && project.isInProgress) {
          // Already running; just give the user feedback.
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Carousel is already generating.')),
          );
        } else {
          // Not started, or previously failed. Either way, kick off
          // (the API will return 429 if rate-limited).
          await startCarouselGeneration(
            context: context,
            apiClient: widget.apiClient,
            businessProfileId: widget.businessProfileId,
          );
          // The status board polls every 3s and will pick up the new
          // project automatically.
        }
        return;
      case 'film':
        if (project != null && project.isReady) {
          await openProjectPreview(context, widget.apiClient, project);
        } else if (project != null && project.isInProgress) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Film is already generating.')),
          );
        } else {
          await startFilmGeneration(
            context: context,
            apiClient: widget.apiClient,
            businessProfileId: widget.businessProfileId,
          );
        }
        return;
    }
  }

  /// Generic full-screen preview used by static tiles (colors, typography)
  /// that don't have a real generation behind them yet. Renders the
  /// supplied [body] widget against the Tamiva background.
  Future<void> _showStaticPreview(
    BuildContext context, {
    required String title,
    required Widget body,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: TamivaColors.background,
          appBar: AppBar(title: Text(title)),
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: body,
          ),
        ),
      ),
    );
  }

  bool get _logoReady => _project != null && _project!.isReady && _project!.assets.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return HeroBannerScaffold(
      heroAsset: 'assets/hero/brand_assets.png',
      title: (_logoReady || _projectId == null)
          ? 'Your brand kit'
          : 'Generating your brand…',
      actions: [LogoutAction(apiClient: widget.apiClient)],
      bottomBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: GradientCtaButton(
            onPressed: _startProCheckout,
            child: const Text('Upgrade to Tamiva Pro · ₹5000/mo'),
          ),
        ),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    if (_error != null) {
      return FullScreenError(
        error: _error!,
        onRetry: () {
          setState(() {
            _error = null;
            _project = null;
            _projectId = null;
          });
          _beginLogoGeneration();
        },
      );
    }

    // Still checking the backend for an existing logo — brief spinner so
    // we never flash the CTA and then swap it for the status board.
    if (_bootstrapping) {
      return const Center(child: CircularProgressIndicator());
    }

    // No logo project yet. Show an explicit "Generate your logo" CTA
    // instead of silently auto-firing on mount — the user chooses when
    // to spend their one free generation, and sees clear feedback.
    if (_projectId == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(28, 40, 28, 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.auto_awesome, size: 44, color: TamivaColors.gold),
            const SizedBox(height: 20),
            Text('Generate your logo',
                textAlign: TextAlign.center, style: textTheme.titleLarge),
            const SizedBox(height: 10),
            Text(
              "We'll craft a clean, modern mark from your business profile. "
              "This is your 1 free logo.",
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium
                  ?.copyWith(color: TamivaColors.textSecondary),
            ),
            const SizedBox(height: 28),
            GradientCtaButton(
              onPressed: _startingLogo ? null : _beginLogoGeneration,
              loading: _startingLogo,
              child: const Text('Generate logo'),
            ),
          ],
        ),
      );
    }

    if (!_logoReady) {
      // Live status board instead of the old single-opaque-spinner -
      // the user can see exactly which artifact is at which stage
      // (queued / generating / ready / failed) and how long each has
      // been running. Once the logo lands, this view is replaced by
      // the full brand-kit reveal below.
      return GenerationStatusBoard(
        apiClient: widget.apiClient,
        businessProfileId: widget.businessProfileId,
        onRowTap: (artifactKey, project) =>
            _handleStatusBoardTap(artifactKey, project),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('YOUR BRAND KIT', style: textTheme.labelMedium),
          const SizedBox(height: 8),
          Text(
            _logoReady
                ? "Here's your starter kit. Unlock the full studio when you're ready."
                : 'Tamiva is generating your kit. Free previews will appear here as each one finishes.',
            style: textTheme.bodyMedium,
          ),
          const SizedBox(height: 28),
          _BrandKitSection(
            title: 'Logo',
            hiddenCount: 3,
            frontChild: _LogoPreview(project: _project),
            onFrontTap: _project != null && _project!.isReady
                ? () => openProjectPreview(context, widget.apiClient, _project!)
                : null,
            onLockedTap: _showComingSoon,
          ),
          const SizedBox(height: 28),
          _BrandKitSection(
            title: 'Brand colors',
            hiddenCount: 4,
            frontChild: _ColorsPreview(profile: _profile),
            onFrontTap: () => _showStaticPreview(
              context,
              title: 'Signature palette',
              body: _ColorsDetailBody(profile: _profile),
            ),
            onLockedTap: _showComingSoon,
          ),
          const SizedBox(height: 28),
          _BrandKitSection(
            title: 'Typography',
            hiddenCount: 4,
            frontChild: _TypographyPreview(profile: _profile),
            onFrontTap: () => _showStaticPreview(
              context,
              title: 'Type system',
              body: _TypographyDetailBody(profile: _profile),
            ),
            onLockedTap: _showComingSoon,
          ),
          const SizedBox(height: 28),
          _BrandKitSection(
            title: 'Social carousel',
            hiddenCount: 5,
            frontChild: _CarouselPreview(
              apiClient: widget.apiClient,
              businessProfileId: widget.businessProfileId,
            ),
            onLockedTap: _showComingSoon,
          ),
          const SizedBox(height: 28),
          _BrandKitSection(
            title: '10-sec brand film',
            hiddenCount: 2,
            frontChild: _FilmPreview(
              apiClient: widget.apiClient,
              businessProfileId: widget.businessProfileId,
            ),
            onLockedTap: _showComingSoon,
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _BrandKitSection extends StatelessWidget {
  final String title;
  final int hiddenCount;
  final Widget frontChild;
  final VoidCallback? onFrontTap;
  final VoidCallback? onLockedTap;

  const _BrandKitSection({
    required this.title,
    required this.hiddenCount,
    required this.frontChild,
    this.onFrontTap,
    this.onLockedTap,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.check_circle, size: 18, color: TamivaColors.gold),
            const SizedBox(width: 8),
            Text(title, style: textTheme.titleLarge),
          ],
        ),
        const SizedBox(height: 14),
        CascadedStack(
          frontChild: frontChild,
          hiddenCount: hiddenCount,
          onFrontTap: onFrontTap,
          onLockedTap: onLockedTap,
        ),
      ],
    );
  }
}

class _LogoPreview extends StatelessWidget {
  final Project? project;
  const _LogoPreview({required this.project});

  @override
  Widget build(BuildContext context) {
    if (project == null || project!.isInProgress) {
      return const ColoredBox(
        color: TamivaColors.surface,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 24,
                width: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(height: 10),
              Text('Generating your logo…',
                  style: TextStyle(fontSize: 12, color: TamivaColors.textSecondary)),
            ],
          ),
        ),
      );
    }
    if (project!.isFailed || project!.assets.isEmpty) {
      return const ColoredBox(
        color: TamivaColors.surface,
        child: Center(
          child: Icon(Icons.auto_awesome, size: 32, color: TamivaColors.textFaint),
        ),
      );
    }
    return NetImage(
      imageUrl: project!.assets.first.url,
      fit: BoxFit.cover,
      placeholder: (_, __) => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      errorWidget: (_, __, ___) =>
          const Icon(Icons.broken_image, color: TamivaColors.textFaint),
    );
  }
}

/// Resolves the palettes the user picked at signup (CSV of keys) into
/// [PaletteStyle]s. Falls back to the default warm palette if none set.
List<PaletteStyle> _resolvePalettes(BusinessProfile? profile) {
  final keys = (profile?.palettePreference ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  return keys.isEmpty
      ? const [PaletteStyles.warm]
      : keys.map(PaletteStyles.byKey).toList();
}

/// Resolves the font pairs the user picked at signup into [FontPair]s.
/// Falls back to the modern default if none set.
List<FontPair> _resolveFonts(BusinessProfile? profile) {
  final keys = (profile?.fontPreference ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  return keys.isEmpty
      ? const [FontPairs.modernDefault]
      : keys.map(FontPairs.byKey).toList();
}

/// The user's brand name for type previews, with a safe fallback.
String _brandName(BusinessProfile? profile) {
  final name = (profile?.name ?? '').trim();
  return name.isEmpty ? 'Your Brand' : name;
}

class _ColorsPreview extends StatelessWidget {
  final BusinessProfile? profile;
  const _ColorsPreview({this.profile});

  @override
  Widget build(BuildContext context) {
    final palettes = _resolvePalettes(profile);
    final hexes = palettes.expand((p) => p.hexCodes).toList();
    final label = palettes
        .map((p) => p.displayName.split('(').first.trim())
        .join(' · ');
    return Container(
      color: TamivaColors.surface,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              for (final hex in hexes) ...[
                Expanded(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _hexToColor(hex),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: TamivaColors.divider),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 14),
          Text(
            label.isEmpty ? 'Signature palette' : label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: TamivaColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class _TypographyPreview extends StatelessWidget {
  final BusinessProfile? profile;
  const _TypographyPreview({this.profile});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final fonts = _resolveFonts(profile);
    final primary = fonts.first;
    final brand = _brandName(profile);
    return Container(
      color: TamivaColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            brand,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.getFont(
              primary.googleFamily,
              fontSize: 34,
              fontWeight: FontWeight.w600,
              color: TamivaColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${primary.displayName} · ${primary.googleFamily}',
            style: textTheme.bodyMedium?.copyWith(color: TamivaColors.gold),
          ),
          if (fonts.length > 1) ...[
            const SizedBox(height: 10),
            Text(
              brand,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.getFont(
                fonts[1].googleFamily,
                fontSize: 22,
                color: TamivaColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// CAROUSEL - tappable, generates 5 slides on first tap.

// Top-level helpers callable from any context (the status board, the
// preview widgets, anywhere). Each asks for confirmation with the right
// cost line, kicks off the generation, and stashes the resulting
// projectId in a registry so other widgets can find it.

/// Confirmation dialog reused for carousel + film + logo retries.
Future<bool?> _confirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String costLine,
  bool strikeCost = false,
  String confirmLabel = 'Generate',
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: TamivaColors.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(TamivaRadii.md),
        side: const BorderSide(color: TamivaColors.divider),
      ),
      title: Text(title, style: Theme.of(ctx).textTheme.titleLarge),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(body, style: Theme.of(ctx).textTheme.bodyMedium),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: TamivaColors.gold.withOpacity(0.12),
              border: Border.all(color: TamivaColors.gold.withOpacity(0.4)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.bolt, color: TamivaColors.gold, size: 16),
                const SizedBox(width: 8),
                Text(costLine,
                    style: Theme.of(ctx).textTheme.labelLarge?.copyWith(
                          color: TamivaColors.gold,
                          decoration:
                              strikeCost ? TextDecoration.lineThrough : null,
                          decorationColor: TamivaColors.gold,
                        )),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '1 Free generation',
            style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                  color: TamivaColors.textFaint,
                  fontSize: 11,
                ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}

/// Kicks off a carousel generation after confirming with the user.
/// On confirm, fires the request and returns the new projectId. Returns
/// null if user cancelled or the request failed.
Future<String?> startCarouselGeneration({
  required BuildContext context,
  required ApiClient apiClient,
  required String businessProfileId,
}) async {
  final confirmed = await _confirmDialog(
    context,
    title: 'Generate your carousel',
    body: "We'll render a 5-slide Brand Story arc using your business "
        "profile and any reference photos you uploaded.",
    costLine: 'Est. ₹150',
    strikeCost: true,
  );
  if (confirmed != true) return null;
  try {
    return await apiClient.createCarouselProject(
      businessProfileId: businessProfileId,
    );
  } on ApiException catch (e) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(UserFacingError.from(e, operation: 'start carousel').message),
      ),
    );
    return null;
  } catch (e) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(UserFacingError.from(e, operation: 'start carousel').message),
      ),
    );
    return null;
  }
}

/// Same shape as startCarouselGeneration but for the 8-second film.
Future<String?> startFilmGeneration({
  required BuildContext context,
  required ApiClient apiClient,
  required String businessProfileId,
}) async {
  final confirmed = await _confirmDialog(
    context,
    title: 'Generate your brand film',
    body: "We'll render a cinematic 8-second opener using your business "
        "profile and any reference photos you uploaded.",
    costLine: 'Est. ₹60–100',
  );
  if (confirmed != true) return null;
  try {
    final result = await apiClient.createVideoProject(
      businessProfileId: businessProfileId,
      tier: 'draft',
    );
    return result.projectId;
  } on ApiException catch (e) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(UserFacingError.from(e, operation: 'start video').message),
      ),
    );
    return null;
  } catch (e) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(UserFacingError.from(e, operation: 'start video').message),
      ),
    );
    return null;
  }
}

/// Retries a failed logo generation. Used by the status board when the
/// user taps a failed logo row.
Future<String?> retryLogoGeneration({
  required BuildContext context,
  required ApiClient apiClient,
  required String businessProfileId,
}) async {
  try {
    return await apiClient.createLogoProject(
      businessProfileId: businessProfileId,
      stylePrompt: 'clean, modern, minimal geometric mark',
    );
  } catch (e) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(UserFacingError.from(e, operation: 'retry logo').message),
      ),
    );
    return null;
  }
}

class _CarouselPreview extends StatefulWidget {
  final ApiClient apiClient;
  final String businessProfileId;
  const _CarouselPreview({
    required this.apiClient,
    required this.businessProfileId,
  });

  @override
  State<_CarouselPreview> createState() => _CarouselPreviewState();
}

class _CarouselPreviewState extends State<_CarouselPreview> {
  Project? _project;
  Timer? _pollTimer;
  bool _starting = false;
  UserFacingError? _startError;

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _onTap() async {
    if (_project?.isReady == true) {
      await _openFullScreenViewer(context);
      return;
    }
    final projectId = await startCarouselGeneration(
      context: context,
      apiClient: widget.apiClient,
      businessProfileId: widget.businessProfileId,
    );
    if (projectId == null) return; // user cancelled or it failed
    _startPolling(projectId);
  }

  void _startPolling(String projectId) {
    _pollTimer?.cancel();
    setState(() => _project = Project(
          id: projectId,
          type: 'carousel',
          status: 'queued',
          assets: const [],
        ));
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _poll(projectId));
    _poll(projectId);
  }

  Future<void> _poll(String projectId) async {
    try {
      final project = await widget.apiClient.getProject(projectId);
      if (!mounted) return;
      setState(() => _project = project);
      if (project.isReady || project.isFailed) {
        _pollTimer?.cancel();
      }
    } catch (_) {
      // transient
    }
  }

  Future<void> _openFullScreenViewer(BuildContext context) async {
    final assets = (_project?.assets ?? const [])
        .toList()
      ..sort((a, b) => (a.slideIndex ?? 0).compareTo(b.slideIndex ?? 0));
    if (assets.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _CarouselViewerScreen(assets: assets),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_startError != null) {
      return _ErrorTile(error: _startError!, onRetry: _onTap);
    }
    if (_starting || (_project?.isInProgress ?? false)) {
      return const _GeneratingTile(
        label: 'Rendering your carousel…',
        eta: Duration(seconds: 90),
      );
    }
    if (_project?.isReady == true) {
      final assets = (_project!.assets.toList()
        ..sort((a, b) => (a.slideIndex ?? 0).compareTo(b.slideIndex ?? 0)));
      return _CarouselReadyPreview(assets: assets, onTap: () => _openFullScreenViewer(context));
    }
    return GestureDetector(
      onTap: _onTap,
      behavior: HitTestBehavior.opaque,
      child: const _CarouselPlaceholder(),
    );
  }
}

class _CarouselPlaceholder extends StatelessWidget {
  const _CarouselPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: TamivaColors.surface,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '5-slide brand story',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Hook · Problem · Vision · Product · CTA',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: TamivaColors.textSecondary),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(Icons.auto_awesome, size: 13, color: TamivaColors.gold),
                      const SizedBox(width: 5),
                      Text(
                        'Tap to generate · Free',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: SizedBox(
              height: double.infinity,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (int i = 2; i >= 0; i--)
                    Positioned(
                      right: 20 + (i * 14),
                      top: 20 + (i * 8),
                      bottom: 20 - (i * 4),
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                [TamivaColors.gold, TamivaColors.ember, TamivaColors.maroon][i],
                                TamivaColors.background,
                              ],
                            ),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: TamivaColors.divider),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CarouselReadyPreview extends StatelessWidget {
  final List<ProjectAsset> assets;
  final VoidCallback onTap;
  const _CarouselReadyPreview({required this.assets, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        color: TamivaColors.surface,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 5,
              child: ClipRRect(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(TamivaRadii.md - 1),
                  bottomLeft: Radius.circular(TamivaRadii.md - 1),
                ),
                child: NetImage(
                  imageUrl: assets.first.url,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  errorWidget: (_, __, ___) =>
                      const Icon(Icons.broken_image, color: TamivaColors.textFaint),
                ),
              ),
            ),
            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '5 slides ready',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: TamivaColors.gold,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Row(
                        children: [
                          for (int i = 1; i < assets.length && i <= 4; i++) ...[
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: NetImage(
                                  imageUrl: assets[i].url,
                                  fit: BoxFit.cover,
                                  placeholder: (_, __) => ColoredBox(
                                    color: TamivaColors.surfaceRaised,
                                    child: const Center(
                                      child: SizedBox(
                                        width: 12,
                                        height: 12,
                                        child: CircularProgressIndicator(strokeWidth: 1),
                                      ),
                                    ),
                                  ),
                                  errorWidget: (_, __, ___) => ColoredBox(
                                    color: TamivaColors.surfaceRaised,
                                    child: const Icon(
                                      Icons.broken_image,
                                      size: 14,
                                      color: TamivaColors.textFaint,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (i < assets.length - 1 && i < 4) const SizedBox(width: 4),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(Icons.touch_app, size: 12, color: TamivaColors.gold),
                        const SizedBox(width: 4),
                        Text(
                          'Tap to view',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// FILM - tappable, generates 8s video on first tap.

class _FilmPreview extends StatefulWidget {
  final ApiClient apiClient;
  final String businessProfileId;

  const _FilmPreview({
    required this.apiClient,
    required this.businessProfileId,
  });

  @override
  State<_FilmPreview> createState() => _FilmPreviewState();
}

class _FilmPreviewState extends State<_FilmPreview> {
  Project? _project;
  Timer? _pollTimer;
  bool _starting = false;
  UserFacingError? _startError;

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _onTap() async {
    if (_project?.isReady == true) {
      await _openFullScreenViewer(context);
      return;
    }
    final projectId = await startFilmGeneration(
      context: context,
      apiClient: widget.apiClient,
      businessProfileId: widget.businessProfileId,
    );
    if (projectId == null) return; // user cancelled or it failed
    _startPolling(projectId);
  }

  void _startPolling(String projectId) {
    _pollTimer?.cancel();
    setState(() => _project = Project(
          id: projectId,
          type: 'video',
          status: 'queued',
          assets: const [],
        ));
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) => _poll(projectId));
    _poll(projectId);
  }

  Future<void> _poll(String projectId) async {
    try {
      final project = await widget.apiClient.getProject(projectId);
      if (!mounted) return;
      setState(() => _project = project);
      if (project.isReady || project.isFailed) {
        _pollTimer?.cancel();
      }
    } catch (_) {
      // transient
    }
  }

  Future<void> _openFullScreenViewer(BuildContext context) async {
    final assets = _project?.assets ?? const [];
    if (assets.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FilmViewerScreen(asset: assets.first),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_startError != null) {
      return _ErrorTile(error: _startError!, onRetry: _onTap);
    }
    if (_starting || (_project?.isInProgress ?? false)) {
      return const _GeneratingTile(
        label: 'Shooting your brand film…',
        eta: Duration(seconds: 60),
      );
    }
    if (_project?.isReady == true && _project!.assets.isNotEmpty) {
      return _FilmReadyPreview(
        asset: _project!.assets.first,
        onTap: () => _openFullScreenViewer(context),
      );
    }
    return GestureDetector(
      onTap: _onTap,
      behavior: HitTestBehavior.opaque,
      child: const _FilmPlaceholder(),
    );
  }
}

class _FilmPlaceholder extends StatelessWidget {
  const _FilmPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [TamivaColors.maroon, TamivaColors.background, TamivaColors.ember],
          stops: [0, 0.55, 1],
        ),
      ),
      child: Stack(
        children: [
          Center(
            child: Container(
              width: 66,
              height: 66,
              decoration: BoxDecoration(
                color: TamivaColors.background.withOpacity(0.6),
                shape: BoxShape.circle,
                border: Border.all(color: TamivaColors.gold, width: 1.5),
              ),
              child: const Icon(
                Icons.play_arrow,
                color: TamivaColors.gold,
                size: 34,
              ),
            ),
          ),
          Positioned(
            left: 16,
            bottom: 14,
            right: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '10-sec cinematic opener',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: TamivaColors.textPrimary,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Golden hour · warm color grade',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: TamivaColors.textSecondary,
                      ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.auto_awesome, size: 12, color: TamivaColors.gold),
                    const SizedBox(width: 5),
                    Text(
                      'Tap to generate · est. ₹60–100',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FilmReadyPreview extends StatelessWidget {
  final ProjectAsset asset;
  final VoidCallback onTap;
  const _FilmReadyPreview({required this.asset, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: [
            NetImage(
              imageUrl: asset.url,
              fit: BoxFit.cover,
              placeholder: (_, __) => const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              errorWidget: (_, __, ___) => Container(
                color: TamivaColors.background,
                child: const Icon(Icons.broken_image, color: TamivaColors.textFaint),
              ),
            ),
            Container(color: Colors.black.withOpacity(0.18)),
            Center(
              child: Container(
                width: 66,
                height: 66,
                decoration: BoxDecoration(
                  color: TamivaColors.background.withOpacity(0.6),
                  shape: BoxShape.circle,
                  border: Border.all(color: TamivaColors.gold, width: 1.5),
                ),
                child: const Icon(
                  Icons.play_arrow,
                  color: TamivaColors.gold,
                  size: 34,
                ),
              ),
            ),
            Positioned(
              left: 16,
              bottom: 14,
              right: 16,
              child: Row(
                children: [
                  const Icon(Icons.movie_creation_outlined, size: 14, color: TamivaColors.gold),
                  const SizedBox(width: 6),
                  Text(
                    'Your 8-sec film · tap to view',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: TamivaColors.textPrimary,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Reusable helpers - generating state, error tile, confirmation dialog.

class _GeneratingTile extends StatelessWidget {
  final String label;
  final Duration eta;
  const _GeneratingTile({required this.label, required this.eta});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: TamivaColors.surface,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              height: 28,
              width: 28,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 10),
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: TamivaColors.textSecondary),
            ),
            const SizedBox(height: 4),
            Text(
              eta.inSeconds < 60
                  ? '~${eta.inSeconds}s left'
                  : '~${(eta.inSeconds / 60).round()} min left',
              style: const TextStyle(fontSize: 10, color: TamivaColors.textFaint),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorTile extends StatelessWidget {
  final UserFacingError error;
  final VoidCallback onRetry;
  const _ErrorTile({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onRetry,
      behavior: HitTestBehavior.opaque,
      child: ColoredBox(
        color: TamivaColors.surface,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.refresh, color: TamivaColors.gold, size: 24),
                const SizedBox(height: 8),
                Text(
                  error.message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: TamivaColors.textSecondary),
                ),
                const SizedBox(height: 4),
                Text(
                  'Tap to retry',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Full-screen viewers (post-generation).

class _CarouselViewerScreen extends StatefulWidget {
  final List<ProjectAsset> assets;
  const _CarouselViewerScreen({required this.assets});

  @override
  State<_CarouselViewerScreen> createState() => _CarouselViewerScreenState();
}

class _CarouselViewerScreenState extends State<_CarouselViewerScreen> {
  final PageController _controller = PageController();
  int _index = 0;

  static const _roles = ['Hook', 'Problem', 'Vision', 'Product', 'CTA'];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TamivaColors.background,
      appBar: AppBar(
        title: Text(
          '${_index + 1} / ${widget.assets.length} - ${_roles[_index.clamp(0, _roles.length - 1)]}',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_rounded),
            tooltip: 'Save slide to gallery',
            onPressed: () =>
                _downloadImageAsset(context, widget.assets[_index].url),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.assets.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) {
          final a = widget.assets[i];
          return Padding(
            padding: const EdgeInsets.all(20),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(TamivaRadii.md),
              child: NetImage(
                imageUrl: a.url,
                fit: BoxFit.contain,
                placeholder: (_, __) => const Center(
                  child: CircularProgressIndicator(),
                ),
                errorWidget: (_, __, ___) => const Center(
                  child: Icon(Icons.broken_image, color: TamivaColors.textFaint, size: 32),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FilmViewerScreen extends StatelessWidget {
  final ProjectAsset asset;
  const _FilmViewerScreen({required this.asset});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TamivaColors.background,
      appBar: AppBar(
        title: const Text('Your brand film'),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new_rounded),
            tooltip: 'Open / download film',
            onPressed: () => _openAssetInBrowser(context, asset.url),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(TamivaRadii.md),
                child: NetImage(
                  imageUrl: asset.url,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => const Center(
                    child: CircularProgressIndicator(),
                  ),
                  errorWidget: (_, __, ___) => const Center(
                    child: Icon(Icons.broken_image, color: TamivaColors.textFaint, size: 32),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Tap the link below to open in your browser. (In-app video playback lands in the next milestone.)',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            SelectableText(
              asset.url,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: TamivaColors.gold,
                    decoration: TextDecoration.underline,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen viewer for a finished logo. Swipeable across all
/// variants if the project produced more than one (logo jobs request
/// n=4 from OpenAI, so we typically have 4 to flip through).
class _LogoViewerScreen extends StatefulWidget {
  final List<ProjectAsset> assets;
  const _LogoViewerScreen({required this.assets});

  @override
  State<_LogoViewerScreen> createState() => _LogoViewerScreenState();
}

class _LogoViewerScreenState extends State<_LogoViewerScreen> {
  final PageController _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TamivaColors.background,
      appBar: AppBar(
        title: Text('${_index + 1} / ${widget.assets.length} · Logo'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_rounded),
            tooltip: 'Save to gallery',
            onPressed: () =>
                _downloadImageAsset(context, widget.assets[_index].url),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.assets.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) {
          final a = widget.assets[i];
          return Padding(
            padding: const EdgeInsets.all(20),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(TamivaRadii.md),
              child: NetImage(
                imageUrl: a.url,
                fit: BoxFit.contain,
                placeholder: (_, __) => const Center(
                  child: CircularProgressIndicator(),
                ),
                errorWidget: (_, __, ___) => const Center(
                  child: Icon(Icons.broken_image,
                      color: TamivaColors.textFaint, size: 32),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Detailed view of the brand palette - used by the static-preview sheet
/// when the user taps the Brand Colors tile.
class _ColorsDetailBody extends StatelessWidget {
  final BusinessProfile? profile;
  const _ColorsDetailBody({this.profile});

  @override
  Widget build(BuildContext context) {
    final palettes = _resolvePalettes(profile);
    // Flatten selected palettes into (palette name, hex) rows.
    final swatches = <(String, String)>[];
    for (final p in palettes) {
      final pname = p.displayName.split('(').first.trim();
      for (final hex in p.hexCodes) {
        swatches.add((pname, hex));
      }
    }
    final textTheme = Theme.of(context).textTheme;
    return ListView.separated(
      itemCount: swatches.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) {
        final (name, hex) = swatches[i];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: TamivaColors.surface,
            borderRadius: BorderRadius.circular(TamivaRadii.sm),
            border: Border.all(color: TamivaColors.divider),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _hexToColor(hex),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: TamivaColors.divider),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(hex.toUpperCase(),
                        style: textTheme.bodyMedium?.copyWith(
                          color: TamivaColors.textSecondary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        )),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Detailed type system view - used by the static-preview sheet when the
/// user taps the Typography tile.
class _TypographyDetailBody extends StatelessWidget {
  final BusinessProfile? profile;
  const _TypographyDetailBody({this.profile});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final fonts = _resolveFonts(profile);
    final brand = _brandName(profile);
    return ListView(
      children: [
        for (final f in fonts) ...[
          _TypeRow(
            label: '${f.displayName} · ${f.googleFamily}',
            sample: brand,
            style: GoogleFonts.getFont(
              f.googleFamily,
              fontSize: 32,
              color: TamivaColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            f.description,
            style: textTheme.bodyMedium
                ?.copyWith(color: TamivaColors.textSecondary),
          ),
          const SizedBox(height: 24),
        ],
      ],
    );
  }
}

class _TypeRow extends StatelessWidget {
  final String label;
  final String sample;
  final TextStyle style;
  const _TypeRow({
    required this.label,
    required this.sample,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: TamivaColors.gold)),
        const SizedBox(height: 4),
        Text(sample, style: style),
      ],
    );
  }
}

Color _hexToColor(String hex) {
  final cleaned = hex.replaceFirst('#', '');
  final v = int.tryParse('FF$cleaned', radix: 16);
  return v == null ? TamivaColors.textFaint : Color(v);
}
