import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../errors/user_facing_error.dart';
import '../services/api_client.dart';
import '../services/asset_saver.dart';
import '../services/share_service.dart';
import '../services/video_downloader.dart';
import '../widgets/net_image.dart';
import '../models/models.dart';
import '../theme/tamiva_theme.dart';
import '../widgets/cascaded_stack.dart';
import '../widgets/full_screen_error.dart';
import '../widgets/hero_scaffold.dart';
import '../widgets/logout_action.dart';
import 'artifacts_screen.dart';
import 'pricing_screen.dart';

/// v37.1: WhatsApp support number used by every generation widget
/// (Logo, Carousel, Film) on failure paths. Surfaced as a tappable
/// WhatsApp icon on each failed tile so users have a single,
/// predictable way to reach support.
const String kTamivaSupportWhatsApp = '8296792087';

/// Opens WhatsApp (web or app) with the support chat pre-filled.
/// Falls back silently if WhatsApp isn't installed - the user can
/// dial the number manually.
Future<void> openTamivaSupportWhatsApp(BuildContext context) async {
  final digits = kTamivaSupportWhatsApp.replaceAll(RegExp(r'[^0-9]'), '');
  final messenger = ScaffoldMessenger.of(context);
  final uri = Uri.parse('https://wa.me/91$digits');
  final launched =
      await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!launched && context.mounted) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          "Couldn't open WhatsApp. Please message $kTamivaSupportWhatsApp directly.",
        ),
      ),
    );
  }
}

/// Tappable WhatsApp icon pill. Used on every generation widget's
/// failure tile so users have one consistent way to reach support.
/// The button is intentionally always-enabled: even after the
/// retry cap is hit, the user can still contact support - it's the
/// only remaining action on a locked tile.
class _TamivaWhatsAppButton extends StatelessWidget {
  final String? label;
  const _TamivaWhatsAppButton({this.label});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF25D366),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => openTamivaSupportWhatsApp(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.chat_bubble_outline,
                color: Colors.white,
                size: 16,
              ),
              const SizedBox(width: 6),
              if (label != null)
                Text(
                  label!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    letterSpacing: 0.3,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

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
  // v36 / S2.15 — cached tier for hiding the Upgrade CTA for Pro (S2.10).
  String _tier = 'free';

  @override
  void initState() {
    super.initState();
    _refreshTier();
  }

  Future<void> _refreshTier() async {
    final refreshed = await widget.apiClient.refreshTier();
    if (refreshed != null && mounted) {
      setState(() => _tier = refreshed.tier);
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  /// v37: any paid tier unlocks Pro features.
  bool get _isPaid => _tier != 'free' && _tier.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return HeroBannerScaffold(
      heroAsset: 'assets/hero/brand_assets.png',
      // v37.1: disable the top-left back button. Leaving mid-flow would
      // orphan an in-flight server-side generation and leave the user
      // without a clear way back to the brand kit. The Logout button
      // in the actions remains available if they really need to leave.
      showBackButton: false,
      // v37.1: title flips based on whether the logo is finished. For
      // a fresh user with no logo yet we render the same brand-kit
      // grid (see _buildBody) so the title should already read
      // "Generating your brand…".
      title: 'Your brand kit',
      actions: [LogoutAction(apiClient: widget.apiClient)],
      bottomBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ArtifactsScreen(
                          apiClient: widget.apiClient,
                          businessProfileId: widget.businessProfileId,
                        ),
                      ),
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: TamivaColors.gold),
                    foregroundColor: TamivaColors.gold,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(TamivaRadii.sm),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),
                  child: const Text('Artifacts'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _isPaid
                    ? const SizedBox.shrink()
                    : GradientCtaButton(
                        onPressed: _openPricingScreen,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.lock_outline,
                                color: Color(0xFF1A0F02), size: 18),
                            SizedBox(width: 8),
                            Text('Upgrade to Tamiva Pro'),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text("Here's your starter kit. Unlock the full studio when you're ready.",
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 28),
          _BrandKitSection(
            title: 'Logo',
            hiddenCount: 0,
            frontChild: _LogoPreview(
              apiClient: widget.apiClient,
              businessProfileId: widget.businessProfileId,
            ),
          ),
          const SizedBox(height: 28),
          _BrandKitSection(
            title: 'Social carousel',
            hiddenCount: 0,
            frontChild: _CarouselPreview(
              apiClient: widget.apiClient,
              businessProfileId: widget.businessProfileId,
            ),
          ),
          const SizedBox(height: 28),
          _BrandKitSection(
            title: '10-sec brand film',
            hiddenCount: 0,
            frontChild: _FilmPreview(
              apiClient: widget.apiClient,
              businessProfileId: widget.businessProfileId,
            ),
          ),
          const SizedBox(height: 28),
          _BrandKitSection(
            title: 'Website',
            hiddenCount: 0,
            frontChild: _WebsiteRollingPreview(onTap: _openPricingScreen),
            onFrontTap: _openPricingScreen,
            showFreePill: false,
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  /// Pushes the new Pricing screen. Used by the Upgrade button and by
  /// the Website tile (locked feature).
  Future<void> _openPricingScreen() async {
    final upgraded = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PricingScreen(
          apiClient: widget.apiClient,
        ),
      ),
    );
    if (upgraded == true && mounted) {
      // Refresh tier + rebuild so any paid-only UI unlocks immediately.
      await _refreshTier();
    }
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

// LOGO - self-contained tile, mirrors the architecture of _CarouselPreview
// exactly so Logo / Carousel / Film all share one shape: an internal
// state machine (idle / starting / in-flight / ready / failed /
// support-lock), independent retry counter with cap, support-only
// fallback after the cap is hit, lock-on-success semantics.

class _LogoPreview extends StatefulWidget {
  final ApiClient apiClient;
  final String businessProfileId;
  const _LogoPreview({
    required this.apiClient,
    required this.businessProfileId,
  });

  @override
  State<_LogoPreview> createState() => _LogoPreviewState();
}

class _LogoPreviewState extends State<_LogoPreview> {
  /// State machine:
  ///   Idle (no project) ──tap──▶ Starting ──success──▶ InProgress
  ///                                                       │
  ///                                                       ├─ready──▶ Ready (terminal; taps open viewer only)
  ///                                                       └─failed─▶ FailedRetryable (until cap reached)
  ///                                                          │
  ///                                                          └─cap reached──▶ LockedSupport (terminal)
  Project? _project;
  Timer? _pollTimer;
  bool _requestInFlight = false;
  DateTime? _generationStartedAt;
  int _attempts = 0;
  static const int _maxAttempts = 3;
  bool _everSucceeded = false;

  @override
  void initState() {
    super.initState();
    _bootstrapFromExistingProject();
  }

  Future<void> _bootstrapFromExistingProject() async {
    try {
      final projects = await widget.apiClient
          .getBusinessProfileProjects(widget.businessProfileId);
      if (!mounted) return;
      final logo = projects.logo;
      if (logo == null) return;
      _seedFromServerProject(logo);
    } catch (_) {
      // best-effort
    }
  }

  /// Bring the local state machine in line with whatever the server
  /// already has. Idempotent; safe to call on every mount.
  void _seedFromServerProject(Project logo) {
    if (logo.isReady && logo.assets.isNotEmpty) {
      setState(() {
        _project = logo;
        _everSucceeded = true;
      });
      return;
    }
    if (logo.isFailed) {
      setState(() {
        _project = logo;
      });
      return;
    }
    if (logo.isInProgress) {
      _startPolling(logo.id, seed: logo);
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  bool get _isGenerating =>
      _requestInFlight || (_project?.isInProgress ?? false);

  bool get _isLockedBehindSupport =>
      !_everSucceeded &&
      _project != null &&
      _project!.isFailed &&
      _attempts >= _maxAttempts;

  Future<void> _onTap() async {
    // Once we've ever succeeded, taps are pure navigation.
    if (_everSucceeded) {
      if (_project != null && _project!.assets.isNotEmpty) {
        await _openFullScreenViewer(context);
      }
      return;
    }
    // Tap during an in-flight request: drop silently.
    if (_isGenerating) return;
    // Hit the cap without ever succeeding: lock the tile.
    if (_isLockedBehindSupport) return;
    // Project ready with assets: open it.
    if (_project != null && _project!.assets.isNotEmpty) {
      await _openFullScreenViewer(context);
      return;
    }
    // Project exists but failed: open the partial assets if any,
    // otherwise start a new attempt.
    if (_project != null && _project!.isFailed) {
      if (_project!.assets.isNotEmpty) {
        await _openFullScreenViewer(context);
        return;
      }
      // else: fall through to start a new attempt.
    }
    // First tap or retry after a failed run with no assets.
    await _startGenerationAttempt();
  }

  /// Fires a single startLogoGeneration request, wires the result
  /// into our state machine, and bumps the attempt counter. Never
  /// throws - all errors are surfaced via [_project] + [_attempts].
  Future<void> _startGenerationAttempt() async {
    if (_requestInFlight) return;
    setState(() {
      _requestInFlight = true;
      _attempts += 1;
      _generationStartedAt = DateTime.now();
      _project = null;
    });
    String? projectId;
    try {
      projectId = await startLogoGeneration(
        context: context,
        apiClient: widget.apiClient,
        businessProfileId: widget.businessProfileId,
      );
    } catch (_) {
      // startLogoGeneration already surfaced a SnackBar and returned null.
    }
    if (!mounted) return;
    if (projectId == null) {
      setState(() => _requestInFlight = false);
      return;
    }
    setState(() {
      _project = Project(
        id: projectId!,
        type: 'logo',
        status: 'queued',
        assets: const [],
      );
    });
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _poll(projectId!),
    );
    _poll(projectId);
  }

  void _startPolling(String projectId, {Project? seed}) {
    _pollTimer?.cancel();
    setState(() => _project = seed ??
        Project(
          id: projectId,
          type: 'logo',
          status: 'queued',
          assets: const [],
        ));
    _pollTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _poll(projectId!),
    );
    _poll(projectId);
  }

  Future<void> _poll(String projectId) async {
    try {
      final project = await widget.apiClient.getProject(projectId);
      if (!mounted) return;
      final succeeded = project.isReady && project.assets.isNotEmpty;
      final failed = project.isFailed;
      setState(() {
        _project = project;
        if (succeeded) _everSucceeded = true;
      });
      if (succeeded || failed) {
        _pollTimer?.cancel();
      }
    } catch (_) {
      // transient - keep polling
    }
  }

  Future<void> _openFullScreenViewer(BuildContext context) async {
    if (_project == null || _project!.assets.isEmpty) return;
    await openProjectPreview(context, widget.apiClient, _project!);
  }

  @override
  Widget build(BuildContext context) {
    // Generate (in-flight request or queued / generating project).
    if (_isGenerating) {
      return _GeneratingTile(
        message: 'Your Logo is getting generated…',
        startedAt: _generationStartedAt ?? DateTime.now(),
      );
    }
    // Ready: show the artifact. The success flag is sticky.
    if (_everSucceeded && _project != null && _project!.assets.isNotEmpty) {
      return _LogoReadyPreview(
        assets: _project!.assets,
        onTap: () => _openFullScreenViewer(context),
      );
    }
    // Cap reached without any success: lock the tile.
    if (_isLockedBehindSupport) {
      return const _LogoSupportLockTile();
    }
    // Failed but still under the cap: tap to retry.
    if (_project != null && _project!.isFailed) {
      return GestureDetector(
        onTap: _onTap,
        behavior: HitTestBehavior.opaque,
        child: _LogoFailedTile(
          attemptsLeft: _maxAttempts - _attempts,
          onTap: _onTap,
        ),
      );
    }
    // No project yet - the "first tap creates the artifact" entry point.
    return GestureDetector(
      onTap: _onTap,
      behavior: HitTestBehavior.opaque,
      child: const _LogoPlaceholder(),
    );
  }
}

class _LogoPlaceholder extends StatelessWidget {
  const _LogoPlaceholder();

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
                    'Your brand mark',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Clean · Modern · Icon-led',
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
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 14, 14, 14),
                child: Container(
                  decoration: BoxDecoration(
                    color: TamivaColors.surfaceRaised,
                    borderRadius: BorderRadius.circular(TamivaRadii.md - 2),
                    border: Border.all(
                      color: TamivaColors.gold.withOpacity(0.25),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.auto_awesome_outlined,
                    color: TamivaColors.gold,
                    size: 36,
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

class _LogoReadyPreview extends StatelessWidget {
  final List<ProjectAsset> assets;
  final VoidCallback onTap;
  const _LogoReadyPreview({required this.assets, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final asset = assets.first;
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
                  imageUrl: asset.url,
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
                      'Logo ready',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: TamivaColors.gold,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tap to view full size',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: TamivaColors.textSecondary,
                          ),
                    ),
                    Row(
                      children: [
                        const Icon(Icons.touch_app, size: 12, color: TamivaColors.gold),
                        const SizedBox(width: 4),
                        Text(
                          'Tap',
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                color: TamivaColors.gold,
                              ),
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

class _LogoFailedTile extends StatelessWidget {
  final int attemptsLeft;
  final VoidCallback onTap;
  const _LogoFailedTile({required this.attemptsLeft, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final remainingLabel = attemptsLeft > 0
        ? 'Tap to retry · $attemptsLeft attempt${attemptsLeft == 1 ? '' : 's'} left'
        : 'No retries left · contact support';
    return Container(
      color: TamivaColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: TamivaColors.error, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: attemptsLeft > 0 ? onTap : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Logo generation failed',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    remainingLabel,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: TamivaColors.textSecondary,
                        ),
                  ),
                ],
              ),
            ),
          ),
          const _TamivaWhatsAppButton(),
        ],
      ),
    );
  }
}

class _LogoSupportLockTile extends StatelessWidget {
  const _LogoSupportLockTile();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: TamivaColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          const Icon(Icons.support_agent_outlined,
              color: TamivaColors.gold, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  "We couldn't generate this logo",
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  "Tap WhatsApp to reach support. We'll start a fresh run once we hear back.",
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: TamivaColors.textSecondary,
                      ),
                ),
              ],
            ),
          ),
          const _TamivaWhatsAppButton(label: 'Support'),
        ],
      ),
    );
  }
}



/// v37: Locked placeholder shown in the Website _BrandKitSection.
/// Tapping anywhere on it opens the Pricing screen.
class _WebsiteLockedPreview extends StatelessWidget {
  const _WebsiteLockedPreview();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: TamivaColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: TamivaColors.gold.withOpacity(0.12),
              borderRadius: BorderRadius.circular(TamivaRadii.sm),
              border: Border.all(color: TamivaColors.gold.withOpacity(0.4)),
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.language,
              color: TamivaColors.gold,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'AI Website',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Tap to choose a plan',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: TamivaColors.gold,
                      ),
                ),
              ],
            ),
          ),
          const Icon(Icons.lock_outline, color: TamivaColors.gold, size: 20),
        ],
      ),
    );
  }
}

/// v37: hero artwork for the Website _BrandKitSection. The asset
/// is rendered 2x the visible tile height and translated from y=0
/// down to y=-tileHeight on a continuous loop — a slow vertical
/// pan that gives the locked tile a "living" feel before the user
/// taps to enter the pricing flow.
///
/// The animation only runs while the widget is mounted. On tap the
/// controller freezes (so the user lands on the frame they tapped),
/// and [onTap] is fired so the brand kit can route to Pricing.
///
/// If the asset isn't on disk (e.g. a developer machine before the
/// asset is bundled), the widget degrades gracefully to a static
/// placeholder — no pan, no crash.
// v37.1: Website tile in the brand kit now renders a static `.gif`
// asset (`assets/hero/tamiva_website_preview.gif`) instead of the
// previous AnimatedBuilder-driven rolling preview. The gif is bundled
// via `pubspec.yaml` under `flutter.assets: assets/hero/`. Tapping the
// tile still routes to Pricing — there are no real Website artifacts
// to open yet, so the gif is the visual preview, not an openable
// artifact.
class _WebsiteRollingPreview extends StatelessWidget {
  final VoidCallback onTap;
  const _WebsiteRollingPreview({required this.onTap});

  /// v37.1: height matches the other brand-kit tiles so the layout
  /// doesn't reflow when the gif replaces the rolling preview.
  static const double _tileHeight = 180;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(TamivaRadii.md - 1),
        child: SizedBox(
          height: _tileHeight,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The gif artwork. fit: BoxFit.cover preserves the aspect
              // ratio and crops any overflow — the gif has its own
              // visual hierarchy so we don't need to slice-and-pan it.
              Image.asset(
                'assets/hero/tamiva_website_preview.gif',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) {
                  // Asset missing or corrupt. Render a clean static
                  // placeholder that still routes to Pricing so the
                  // tap target is never dead.
                  return Container(
                    color: TamivaColors.surface,
                    alignment: Alignment.center,
                    child: Text(
                      'Tap to choose a plan',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: TamivaColors.gold,
                          ),
                    ),
                  );
                },
              ),
              // Bottom scrim so the caption reads cleanly over the
              // bottom of the gif.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withOpacity(0.55),
                      ],
                    ),
                  ),
                ),
              ),
              // WhatsApp support shortcut, centered horizontally and
              // placed below the tile's vertical center (top: 78 on a
              // 180-px tile puts the button center at ~y=100, well clear
              // of the bottom "Coming soon" caption at y=164+).
              //
              // Size: 44dp outer circle (Apple/Google HIG minimum tap
              // target), 22dp icon. WhatsApp brand green #25D366.
              Positioned(
                left: 0,
                right: 0,
                top: 78,
                child: Center(
                  child: Material(
                    color: const Color(0xFF25D366),
                    shape: const CircleBorder(),
                    elevation: 4,
                    shadowColor: Colors.black.withOpacity(0.4),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => openTamivaSupportWhatsApp(context),
                      child: Tooltip(
                        message: 'Chat with Tamiva support',
                        child: Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.chat_bubble_outlined,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              const Positioned(
                left: 16,
                right: 16,
                bottom: 14,
                child: Row(
                  children: [
                    Icon(
                      Icons.touch_app_outlined,
                      color: TamivaColors.gold,
                      size: 16,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Coming soon',
                        style: TextStyle(
                          color: TamivaColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
// LOGO - tappable, generates a single logo concept on first tap.

// Top-level helpers callable from any context (the status board, the
// preview widgets, anywhere). They fire the API directly - no
// confirmation dialog (the tap on the tile is the user's intent; the
// tile copy already shows the cost line).

/// Kicks off a logo generation. Fires the request and returns the
/// new projectId. Returns null on failure.
///
/// v37: dropped the cost-estimate confirmation dialog. The tap on the
/// tile is itself the user's intent; an extra modal was just friction
/// now that plans are flat (every paid plan gets unlimited). The
/// "Cost" line on the tile is enough context.
Future<String?> startLogoGeneration({
  required BuildContext context,
  required ApiClient apiClient,
  required String businessProfileId,
}) async {
  try {
    return await apiClient.createLogoProject(
      businessProfileId: businessProfileId,
      stylePrompt: 'clean, modern, minimal geometric mark',
    );
  } on ApiException catch (e) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(UserFacingError.from(e, operation: 'start logo').message),
      ),
    );
    return null;
  } catch (e) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(UserFacingError.from(e, operation: 'start logo').message),
      ),
    );
    return null;
  }
}



// CAROUSEL - tappable, generates 5 slides on first tap.

// Top-level helpers callable from any context (the status board, the
// preview widgets, anywhere). They fire the API directly — no
// confirmation dialog (the tap on the tile is the user's intent; the
// tile copy already shows the cost line).

/// Kicks off a carousel generation. Fires the request and returns the
/// new projectId. Returns null on failure.
///
/// v37: dropped the cost-estimate confirmation dialog. The tap on the
/// tile is itself the user's intent; an extra modal was just friction
/// now that plans are flat (every paid plan gets unlimited). The
/// "Cost" line on the tile is enough context.
Future<String?> startCarouselGeneration({
  required BuildContext context,
  required ApiClient apiClient,
  required String businessProfileId,
}) async {
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
/// v37: dropped the cost-estimate confirmation dialog (see
/// startCarouselGeneration for the rationale).
Future<String?> startFilmGeneration({
  required BuildContext context,
  required ApiClient apiClient,
  required String businessProfileId,
}) async {
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
  /// State machine:
  ///   Idle (no project) ──tap──▶ Starting ──success──▶ InProgress
  ///                                                       │
  ///                                                       ├─ready──▶ Ready (terminal; taps open viewer only)
  ///                                                       └─failed─▶ FailedRetryable (until cap reached)
  ///                                                          │
  ///                                                          └─cap reached──▶ LockedSupport (terminal)
  ///
  /// Taps while [_requestInFlight] is true are dropped silently — the
  /// first click is the one that creates the artifact, and any
  /// double-tap before the backend has answered is a no-op (no
  /// SnackBar, no duplicate request).
  Project? _project;
  Timer? _pollTimer;
  bool _requestInFlight = false;
  /// v37.1: wall-clock time the current generation started. Captured
  /// at the same `setState` that flips `_requestInFlight = true` so
  /// the `_GeneratingTile` can render an accurate elapsed counter
  /// even on its first frame (no 00:00 → 00:01 flash). The state is
  /// non-null only while a generation is in flight.
  DateTime? _generationStartedAt;
  /// Number of user-visible attempts that have been started. Bumps on
  /// both start-call failures and poll-reported failures. Cleared on
  /// a successful ready state (because once the user has an artifact,
  /// the cap becomes irrelevant — subsequent taps just open it).
  int _attempts = 0;
  /// Hard cap on retry attempts. After this many failed attempts the
  /// tile locks behind a "Contact support" message with no
  /// tap-to-retry. See [_CarouselSupportLockTile].
  static const int _maxAttempts = 3;
  /// Set true the first time we see a project in the ready state.
  /// Once set, never re-enter the generation path.
  bool _everSucceeded = false;

  @override
  void initState() {
    super.initState();
    // v36 / S2.13 — adopt an in-flight carousel on re-entry. If the
    // backend already has a project for this profile (success or
    // failure), seed our state from it.
    _bootstrapFromExistingProject();
  }

  Future<void> _bootstrapFromExistingProject() async {
    try {
      final projects = await widget.apiClient
          .getBusinessProfileProjects(widget.businessProfileId);
      if (!mounted) return;
      final carousel = projects.carousel;
      if (carousel == null) return;
      _seedFromServerProject(carousel);
    } catch (_) {
      // best-effort
    }
  }

  /// Bring the local state machine in line with whatever the server
  /// already has. Idempotent; safe to call on every mount.
  void _seedFromServerProject(Project carousel) {
    if (carousel.isReady && carousel.assets.isNotEmpty) {
      setState(() {
        _project = carousel;
        _everSucceeded = true;
        // A ready project on the server means at least one attempt
        // already succeeded, so we treat attempts as "consumed but
        // irrelevant" — subsequent taps will just open the viewer.
      });
      return;
    }
    if (carousel.isFailed) {
      setState(() {
        _project = carousel;
        // Don't auto-bump attempts here — we don't know how many
        // prior attempts the user burned before this failed one.
        // The cap is enforced when the *next* tap happens; the
        // failed tile gives the user a chance to retry up to
        // _maxAttempts, and the cap locks after that.
      });
      return;
    }
    if (carousel.isInProgress) {
      // Adopt the in-flight run so we can poll for its result.
      _startPolling(carousel.id, seed: carousel);
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  /// True while a generation request is in flight to the backend, OR
  /// while a started project is still queued / generating. The build
  /// method uses this to decide between a spinner and a placeholder.
  bool get _isGenerating =>
      _requestInFlight || (_project?.isInProgress ?? false);

  /// True once the user has hit the retry cap with no success.
  /// The tile then renders a non-tappable support-lock state.
  bool get _isLockedBehindSupport =>
      !_everSucceeded &&
      _project != null &&
      _project!.isFailed &&
      _attempts >= _maxAttempts;

  Future<void> _onTap() async {
    // ── 1. Once we've ever succeeded, taps are pure navigation.
    if (_everSucceeded) {
      if (_project != null && _project!.assets.isNotEmpty) {
        await _openFullScreenViewer(context);
      }
      return;
    }

    // ── 2. Tap during an in-flight request: drop silently. The user
    //     already triggered a generation; the backend is the source
    //     of truth and we don't want duplicate work.
    if (_isGenerating) return;

    // ── 3. Hit the cap without ever succeeding: lock the tile.
    if (_isLockedBehindSupport) return;

    // ── 4. Project ready with assets: open it (defensive — handled
    //     above by _everSucceeded too).
    if (_project != null && _project!.assets.isNotEmpty) {
      await _openFullScreenViewer(context);
      return;
    }

    // ── 5. Project exists but failed: open the partial assets if any,
    //     otherwise start a new attempt.
    if (_project != null && _project!.isFailed) {
      if (_project!.assets.isNotEmpty) {
        await _openFullScreenViewer(context);
        return;
      }
      // else: fall through to start a new attempt.
    }

    // ── 6. First tap (no project yet) OR a retry after a failed run
    //     with no assets. Fire the start call.
    await _startGenerationAttempt();
  }

  /// Fires a single startCarouselGeneration request, wires the result
  /// into our state machine, and bumps the attempt counter. Never
  /// throws — all errors are surfaced via [_project] + [_attempts].
  Future<void> _startGenerationAttempt() async {
    if (_requestInFlight) return;
    setState(() {
      _requestInFlight = true;
      _attempts += 1;
      _generationStartedAt = DateTime.now();
    });
    String? projectId;
    try {
      projectId = await startCarouselGeneration(
        context: context,
        apiClient: widget.apiClient,
        businessProfileId: widget.businessProfileId,
      );
    } catch (_) {
      // startCarouselGeneration itself already surfaced a SnackBar
      // and returned null. We've already bumped _attempts; the
      // build() method will pick that up.
    }
    if (!mounted) {
      // Widget disposed mid-request. Don't touch state.
      return;
    }
    if (projectId == null) {
      // User cancelled OR the start call failed. Either way, nothing
      // to poll. The _attempts counter is already bumped.
      // v37.1: drop _requestInFlight so the user can retry the
      // tap. Wrap in setState so the build picks it up.
      setState(() => _requestInFlight = false);
      return;
    }
    // v37.1: flicker fix. Before, _requestInFlight was flipped to
    // false and then _startPolling set _project in a separate
    // setState. Between the two, build() evaluated _isGenerating as
    // false (because _project was still null) and rendered the
    // "Tap to generate" placeholder for one frame. Setting
    // _requestInFlight=false and _project=queued in the SAME
    // setState keeps _isGenerating true throughout the transition.
    //
    // Promote projectId to a non-nullable local so the closure
    // passed to Timer.periodic captures a String (Dart's flow
    // analysis can't promote across the closure boundary).
    final pid = projectId;
    setState(() {
      _requestInFlight = false;
      _project = Project(
        id: pid,
        type: 'carousel',
        status: 'queued',
        assets: const [],
      );
    });
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _poll(pid),
    );
    _poll(pid);
  }

  void _startPolling(String projectId, {Project? seed}) {
    _pollTimer?.cancel();
    setState(() => _project = seed ??
        Project(
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
      // If the project became ready with assets, lock the success flag
      // so subsequent taps can never re-enter the generation path.
      final succeeded = project.isReady && project.assets.isNotEmpty;
      final failed = project.isFailed;
      setState(() {
        _project = project;
        if (succeeded) _everSucceeded = true;
      });
      if (succeeded || failed) {
        _pollTimer?.cancel();
      }
    } catch (_) {
      // transient — keep polling
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
    // Generate (in-flight request or queued / generating project).
    if (_isGenerating) {
      return _GeneratingTile(
        message: 'Your Social Carousel is getting generated…',
        startedAt: _generationStartedAt ?? DateTime.now(),
      );
    }
    // Ready: show the artifact. The success flag is sticky; once set,
    // we never leave this branch unless the widget is unmounted.
    if (_everSucceeded && _project != null && _project!.assets.isNotEmpty) {
      final assets = (_project!.assets.toList()
        ..sort((a, b) => (a.slideIndex ?? 0).compareTo(b.slideIndex ?? 0)));
      return _CarouselReadyPreview(
        assets: assets,
        onTap: () => _openFullScreenViewer(context),
      );
    }
    // Cap reached without any success: lock the tile.
    if (_isLockedBehindSupport) {
      return const _CarouselSupportLockTile();
    }
    // Failed but still under the cap: tap to retry. The tile copy
    // surfaces how many attempts are left.
    if (_project != null && _project!.isFailed) {
      return GestureDetector(
        onTap: _onTap,
        behavior: HitTestBehavior.opaque,
        child: _CarouselFailedTile(
          attemptsLeft: _maxAttempts - _attempts,
          onTap: _onTap,
        ),
      );
    }
    // No project yet — the "first tap creates the artifact" entry point.
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

/// v37: shown when a carousel project exists but failed with no
/// recoverable assets. Tapping surfaces the failure via SnackBar —
/// the second tap on a failed run does NOT start a new generation.
class _CarouselFailedTile extends StatelessWidget {
  /// Number of generation attempts still available. Shown so the user
  /// knows how many taps remain before the tile locks.
  final int attemptsLeft;

  /// Tapping the row body retries. WhatsApp pill has its own onTap.
  final VoidCallback onTap;

  const _CarouselFailedTile({
    required this.attemptsLeft,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final remainingLabel = attemptsLeft > 0
        ? 'Tap to retry · $attemptsLeft attempt${attemptsLeft == 1 ? '' : 's'} left'
        : 'No retries left · contact support';
    return Container(
      color: TamivaColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline,
            color: TamivaColors.error,
            size: 26,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: attemptsLeft > 0 ? onTap : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Carousel generation failed',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    remainingLabel,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: TamivaColors.textSecondary,
                        ),
                  ),
                ],
              ),
            ),
          ),
          const _TamivaWhatsAppButton(),
        ],
      ),
    );
  }
}

/// v37: shown after the user has burned through the retry cap with
/// no successful generation. v37.1: the tile now exposes the same
/// WhatsApp support affordance as the retryable failure tile, since
/// contacting support is the only remaining useful action.
class _CarouselSupportLockTile extends StatelessWidget {
  const _CarouselSupportLockTile();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: TamivaColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      child: Row(
        children: [
          const Icon(
            Icons.support_agent_outlined,
            color: TamivaColors.gold,
            size: 26,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'We couldn\'t generate this carousel',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Tap WhatsApp to reach support. We\'ll start a fresh run once we hear back.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: TamivaColors.textSecondary,
                      ),
                ),
              ],
            ),
          ),
          const _TamivaWhatsAppButton(label: 'Support'),
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
  /// Mirrors [_CarouselPreviewState] — see the docstring there for
  /// the full state machine. Taps during an in-flight request are
  /// dropped silently. Once a successful artifact exists, taps
  /// only open the viewer.
  Project? _project;
  Timer? _pollTimer;
  bool _requestInFlight = false;
  /// v37.1: wall-clock time the current generation started. Captured
  /// at the same `setState` that flips `_requestInFlight = true` so
  /// the `_GeneratingTile` can render an accurate elapsed counter
  /// even on its first frame. The state is non-null only while a
  /// generation is in flight.
  DateTime? _generationStartedAt;
  int _attempts = 0;
  static const int _maxAttempts = 3;
  bool _everSucceeded = false;

  @override
  void initState() {
    super.initState();
    // v36 / S2.13 — adopt in-flight film on re-entry.
    _bootstrapFromExistingProject();
  }

  Future<void> _bootstrapFromExistingProject() async {
    try {
      final projects = await widget.apiClient
          .getBusinessProfileProjects(widget.businessProfileId);
      if (!mounted) return;
      final video = projects.video;
      if (video == null) return;
      _seedFromServerProject(video);
    } catch (_) {
      // best-effort
    }
  }

  void _seedFromServerProject(Project video) {
    if (video.isReady && video.assets.isNotEmpty) {
      setState(() {
        _project = video;
        _everSucceeded = true;
      });
      return;
    }
    if (video.isFailed) {
      setState(() => _project = video);
      return;
    }
    if (video.isInProgress) {
      _startPolling(video.id, seed: video);
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  /// Fires a single startFilmGeneration request, wires the result
  /// into our state machine, and bumps the attempt counter. Mirrors
  /// [_CarouselPreviewState._startGenerationAttempt].
  Future<void> _startGenerationAttempt() async {
    if (_requestInFlight) return;
    setState(() {
      _requestInFlight = true;
      _attempts += 1;
      _generationStartedAt = DateTime.now();
    });
    String? projectId;
    try {
      projectId = await startFilmGeneration(
        context: context,
        apiClient: widget.apiClient,
        businessProfileId: widget.businessProfileId,
      );
    } catch (_) {
      // startFilmGeneration surfaces its own SnackBar; counter is
      // already bumped for the build() method to pick up.
    }
    if (!mounted) return;
    if (projectId == null) {
      // v37.1: drop _requestInFlight so the user can retry the tap.
      setState(() => _requestInFlight = false);
      return;
    }
    // v37.1: flicker fix (same rationale as carousel). Setting
    // _requestInFlight=false and _project=queued in a single
    // setState keeps _isGenerating true throughout the transition
    // so the placeholder never re-appears between attempts.
    //
    // Promote projectId to a non-nullable local so the closure
    // passed to Timer.periodic captures a String (Dart's flow
    // analysis can't promote across the closure boundary).
    final pid = projectId;
    setState(() {
      _requestInFlight = false;
      _project = Project(
        id: pid,
        type: 'video',
        status: 'queued',
        assets: const [],
      );
    });
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _poll(pid),
    );
    _poll(pid);
  }

  void _startPolling(String projectId, {Project? seed}) {
    _pollTimer?.cancel();
    setState(() => _project = seed ??
        Project(
          id: projectId,
          type: 'video',
          status: 'queued',
          assets: const [],
        ));
    // v37: films poll a bit slower than carousels — they take longer
    // to render server-side.
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) => _poll(projectId));
    _poll(projectId);
  }

  Future<void> _poll(String projectId) async {
    try {
      final project = await widget.apiClient.getProject(projectId);
      if (!mounted) return;
      final succeeded = project.isReady && project.assets.isNotEmpty;
      final failed = project.isFailed;
      setState(() {
        _project = project;
        if (succeeded) _everSucceeded = true;
      });
      if (succeeded || failed) {
        _pollTimer?.cancel();
      }
    } catch (_) {
      // transient — keep polling
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

  bool get _isGenerating =>
      _requestInFlight || (_project?.isInProgress ?? false);

  bool get _isLockedBehindSupport =>
      !_everSucceeded &&
      _project != null &&
      _project!.isFailed &&
      _attempts >= _maxAttempts;

  Future<void> _onTap() async {
    // ── 1. Once we've ever succeeded, taps are pure navigation.
    if (_everSucceeded) {
      if (_project != null && _project!.assets.isNotEmpty) {
        await _openFullScreenViewer(context);
      }
      return;
    }

    // ── 2. Tap during an in-flight request: drop silently.
    if (_isGenerating) return;

    // ── 3. Hit the cap without ever succeeding: lock the tile.
    if (_isLockedBehindSupport) return;

    // ── 4. Project ready with assets: open it.
    if (_project != null && _project!.assets.isNotEmpty) {
      await _openFullScreenViewer(context);
      return;
    }

    // ── 5. Project exists but failed: open partial assets if any,
    //     otherwise start a new attempt.
    if (_project != null && _project!.isFailed) {
      if (_project!.assets.isNotEmpty) {
        await _openFullScreenViewer(context);
        return;
      }
      // else: fall through to start a new attempt.
    }

    // ── 6. First tap (no project yet) OR a retry after a failed run
    //     with no assets. Fire the start call.
    await _startGenerationAttempt();
  }

  @override
  Widget build(BuildContext context) {
    if (_isGenerating) {
      return _GeneratingTile(
        message: 'Your 10-Second Brand Film is getting generated…',
        startedAt: _generationStartedAt ?? DateTime.now(),
      );
    }
    if (_everSucceeded && _project != null && _project!.assets.isNotEmpty) {
      return _FilmReadyPreview(
        asset: _project!.assets.first,
        onTap: () => _openFullScreenViewer(context),
      );
    }
    if (_isLockedBehindSupport) {
      return const _FilmSupportLockTile();
    }
    if (_project != null && _project!.isFailed) {
      return GestureDetector(
        onTap: _onTap,
        behavior: HitTestBehavior.opaque,
        child: _FilmFailedTile(
          attemptsLeft: _maxAttempts - _attempts,
          onTap: _onTap,
        ),
      );
    }
    return GestureDetector(
      onTap: _onTap,
      behavior: HitTestBehavior.opaque,
      child: const _FilmPlaceholder(),
    );
  }
}

/// v37: shown when a film project exists but failed with no
/// recoverable assets. Tapping re-enters the generation path under
/// the [_maxAttempts] cap. The attempt counter surfaces how many
/// taps remain before the tile locks.
class _FilmFailedTile extends StatelessWidget {
  /// Number of generation attempts still available. Shown so the user
  /// knows how many taps remain before the tile locks.
  final int attemptsLeft;

  /// Tapping the row body retries. WhatsApp pill has its own onTap.
  final VoidCallback onTap;

  const _FilmFailedTile({
    required this.attemptsLeft,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final remainingLabel = attemptsLeft > 0
        ? 'Tap to retry · $attemptsLeft attempt${attemptsLeft == 1 ? '' : 's'} left'
        : 'No retries left · contact support';
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [TamivaColors.maroon, TamivaColors.background, TamivaColors.ember],
          stops: [0, 0.55, 1],
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline,
            color: TamivaColors.error,
            size: 26,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: attemptsLeft > 0 ? onTap : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Film generation failed',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    remainingLabel,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: TamivaColors.textSecondary,
                        ),
                  ),
                ],
              ),
            ),
          ),
          const _TamivaWhatsAppButton(),
        ],
      ),
    );
  }
}

/// v37: shown after the user has burned through the retry cap with
/// no successful generation. v37.1: WhatsApp support is the single
/// remaining affordance on a locked tile.
class _FilmSupportLockTile extends StatelessWidget {
  const _FilmSupportLockTile();

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
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      child: Row(
        children: [
          const Icon(
            Icons.support_agent_outlined,
            color: TamivaColors.gold,
            size: 26,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'We couldn\'t generate this film',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Tap WhatsApp to reach support. We\'ll start a fresh run once we hear back.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: TamivaColors.textSecondary,
                      ),
                ),
              ],
            ),
          ),
          const _TamivaWhatsAppButton(label: 'Support'),
        ],
      ),
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

class _GeneratingTile extends StatefulWidget {
  final String message;
  final DateTime startedAt;

  const _GeneratingTile({
    required this.message,
    required this.startedAt,
  });

  @override
  State<_GeneratingTile> createState() => _GeneratingTileState();
}

class _GeneratingTileState extends State<_GeneratingTile> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Tick once per second. We don't manually increment a counter;
    // we compute `now - startedAt` on every tick. That gives the
    // "elapsed time" semantics for free, and also handles the
    // backgrounding case correctly: Flutter pauses Timer.periodic
    // while the app is in the background, and on resume the next
    // tick simply computes the new wall-clock delta — the user
    // sees a single jump rather than a fast-forward animation.
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(widget.startedAt);
    final totalSeconds = elapsed.inSeconds < 0 ? 0 : elapsed.inSeconds;
    final mm = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final ss = (totalSeconds % 60).toString().padLeft(2, '0');
    return ColoredBox(
      color: TamivaColors.surface,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              widget.message,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: TamivaColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '$mm:$ss',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: TamivaColors.gold,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 14),
        ],
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
  bool _savingAll = false;

  static const _roles = ['Hook', 'Problem', 'Vision', 'Product', 'CTA'];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// v36 / S3.17 — save every slide in parallel. Saves the user 5 taps
  /// and gives them a single success/failure SnackBar at the end.
  Future<void> _saveAll() async {
    if (_savingAll) return;
    setState(() => _savingAll = true);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Saving all slides to your gallery…'),
        duration: Duration(seconds: 1),
      ),
    );
    final urls = widget.assets.map((a) => a.url).toList();
    final results = await Future.wait(urls.map((u) => saveImageToGallery(u)));
    if (!mounted) return;
    final failed =
        results.where((r) => !r.ok).map((r) => r.error).toList();
    messenger.hideCurrentSnackBar();
    if (failed.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('All slides saved to your gallery.')),
      );
    } else if (failed.length == urls.length) {
      messenger.showSnackBar(
        SnackBar(content: Text(failed.first ?? "Couldn't save.")),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Saved ${urls.length - failed.length} of ${urls.length} slides.',
          ),
        ),
      );
    }
    setState(() => _savingAll = false);
  }

  Future<void> _shareCurrent() async {
    final url = widget.assets[_index].url;
    await ShareService.shareImageUrl(
      url,
      name:
          'tamiva-carousel-${_index + 1}-${_roles[_index.clamp(0, _roles.length - 1)].toLowerCase()}.png',
      text: 'Slide ${_index + 1} of my Tamiva carousel',
    );
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
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Share slide',
            onPressed: _shareCurrent,
          ),
          IconButton(
            icon: const Icon(Icons.save_alt_rounded),
            tooltip: 'Save all slides',
            onPressed: _savingAll ? null : _saveAll,
          ),
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

class _FilmViewerScreen extends StatefulWidget {
  final ProjectAsset asset;
  const _FilmViewerScreen({required this.asset});

  @override
  State<_FilmViewerScreen> createState() => _FilmViewerScreenState();
}

class _FilmViewerScreenState extends State<_FilmViewerScreen> {
  // v36 / S2.11 — in-app playback via video_player.
  VideoPlayerController? _controller;
  bool _initializing = true;
  String? _initError;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  Future<void> _initController() async {
    try {
      final c = await FilmPlaybackService.controllerFor(widget.asset.url);
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _initializing = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _initError = "Couldn't load the film. Try opening it in a browser.";
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _downloadFilm() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Downloading film…'),
        duration: Duration(seconds: 1),
      ),
    );
    final result = await FilmPlaybackService.downloadForSharing(
      widget.asset.url,
    );
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    if (result.ok && result.bytes != null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Film ready to share.')),
      );
      await ShareService.shareVideoBytes(
        result.bytes!,
        name: 'tamiva-film.mp4',
        text: 'My brand film from Tamiva',
      );
    } else {
      final err = result.error ?? "Couldn't save.";
      messenger.showSnackBar(SnackBar(content: Text(err)));
      if (err.toLowerCase().contains('settings')) {
        messenger.showSnackBar(
          SnackBar(
            content: const Text('Tap to open Settings.'),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: FilmPlaybackService.openAppSettings,
            ),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TamivaColors.background,
      appBar: AppBar(
        title: const Text('Your brand film'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download_outlined),
            tooltip: 'Save film to gallery',
            onPressed: _downloadFilm,
          ),
          IconButton(
            icon: const Icon(Icons.open_in_new_rounded),
            tooltip: 'Open in browser',
            onPressed: () => _openAssetInBrowser(context, widget.asset.url),
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
                child: _buildPlayer(context),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Tap play to watch in-app, or save it to your gallery to share.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayer(BuildContext context) {
    if (_initializing) {
      return const ColoredBox(
        color: TamivaColors.surface,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_initError != null) {
      return ColoredBox(
        color: TamivaColors.surface,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image, color: TamivaColors.textFaint, size: 36),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  _initError!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () => _openAssetInBrowser(context, widget.asset.url),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Open in browser'),
              ),
            ],
          ),
        ),
      );
    }
    final c = _controller!;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
              child: VideoPlayer(c),
            ),
          ),
          GestureDetector(
            onTap: () {
              setState(() {
                c.value.isPlaying ? c.pause() : c.play();
              });
            },
            child: Container(
              color: const Color(0x33000000),
              child: Center(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity: c.value.isPlaying ? 0 : 1,
                  child: const Icon(
                    Icons.play_circle_outline,
                    color: Colors.white,
                    size: 80,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: VideoProgressIndicator(
              c,
              allowScrubbing: true,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              colors: const VideoProgressColors(
                playedColor: TamivaColors.gold,
                bufferedColor: Color(0x55D4A72C),
                backgroundColor: Color(0x33FFFFFF),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen viewer for a finished logo. Swipeable across all
/// variants if the project produced more than one.
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
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Share',
            onPressed: () => ShareService.shareImageUrl(
              widget.assets[_index].url,
              name: 'tamiva-logo.png',
              text: 'My brand from Tamiva',
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Regenerate',
            onPressed: () {
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Open the brand kit to generate a fresh logo.',
                  ),
                ),
              );
            },
          ),
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

// (v37) Brand Colors + Typography detail widgets removed. The
// signup-time palette / typography preferences remain on BusinessProfile;
// only the dashboard surfaces were dropped.

// v37: hex-to-color helper retained as a no-dependency utility.
Color _hexToColor(String hex) {
  final cleaned = hex.replaceFirst('#', '');
  final v = int.tryParse('FF$cleaned', radix: 16);
  return v == null ? TamivaColors.textFaint : Color(v);
}
