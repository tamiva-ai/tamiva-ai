import 'package:flutter/material.dart';

import '../errors/user_facing_error.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../services/asset_saver.dart';
import '../theme/tamiva_theme.dart';
import '../widgets/hero_scaffold.dart';
import '../widgets/logout_action.dart';
import '../widgets/net_image.dart';

/// "Artifacts" screen — four folders, one per generation type. Each
/// folder shows all generated artifacts of that type, fetched via the
/// existing /business-profiles/:id/projects/all endpoint.
///
/// Tapping a folder opens its grid; tapping an artifact opens the
/// full-screen viewer with Download + Back.
class ArtifactsScreen extends StatefulWidget {
  final ApiClient apiClient;
  final String businessProfileId;

  const ArtifactsScreen({
    super.key,
    required this.apiClient,
    required this.businessProfileId,
  });

  @override
  State<ArtifactsScreen> createState() => _ArtifactsScreenState();
}

class _ArtifactsScreenState extends State<ArtifactsScreen> {
  List<BusinessProfileProjectSummary> _logos = const [];
  List<BusinessProfileProjectSummary> _carousels = const [];
  List<BusinessProfileProjectSummary> _videos = const [];
  // Website artifacts land in a future milestone; folder shows "Coming
  // soon" until the generator ships.
  static const List<BusinessProfileProjectSummary> _websites = [];

  bool _loading = true;
  UserFacingError? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Fetch every project the user has ever produced (any status),
      // then bucket by type. Endpoint: GET
      // /business-profiles/:id/projects/all (already on ApiClient).
      final history = await widget.apiClient
          .getBusinessProfileHistory(widget.businessProfileId);
      // Use the most-recent project of each type as the latest
      // representative. The history endpoint already returns the most
      // recent first per type (backend sorts desc by updatedAt).
      final logos = history.where((p) => p.type == 'logo').toList();
      final carousels = history.where((p) => p.type == 'carousel').toList();
      final videos = history.where((p) => p.type == 'video').toList();

      if (!mounted) return;
      setState(() {
        _logos = logos;
        _carousels = carousels;
        _videos = videos;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = UserFacingError.from(e, operation: 'load your artifacts');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return HeroBannerScaffold(
      heroAsset: 'assets/hero/brand_assets.png',
      title: 'Artifacts',
      actions: [LogoutAction(apiClient: widget.apiClient)],
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: TamivaColors.gold),
              )
            : _error != null
                ? _ErrorView(error: _error!, onRetry: _load)
                : RefreshIndicator(
                    onRefresh: _load,
                    color: TamivaColors.gold,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                      children: [
                        Text(
                          'Everything Tamiva has generated for your brand.',
                          style: textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 24),
                        _FolderTile(
                          title: 'Logo',
                          subtitle: _folderSubtitle(_logos),
                          icon: Icons.auto_awesome_outlined,
                          onTap: () => _openFolder('Logo', _logos),
                        ),
                        const SizedBox(height: 12),
                        _FolderTile(
                          title: 'Social Carousel',
                          subtitle: _folderSubtitle(_carousels),
                          icon: Icons.collections_outlined,
                          onTap: () => _openFolder(
                            'Social Carousel',
                            _carousels,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _FolderTile(
                          title: 'Brand Film',
                          subtitle: _folderSubtitle(_videos),
                          icon: Icons.movie_creation_outlined,
                          onTap: () => _openFolder(
                            'Brand Film',
                            _videos,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _FolderTile(
                          title: 'Website',
                          subtitle: 'Coming soon',
                          icon: Icons.language_outlined,
                          onTap: () => ScaffoldMessenger.of(context)
                              .showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Website artifacts ship in a future milestone.',
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
      ),
    );
  }

  String _folderSubtitle(List<BusinessProfileProjectSummary> projects) {
    final ready =
        projects.where((p) => p.status == 'ready').length;
    if (projects.isEmpty) return 'No artifacts yet';
    if (ready == 0) return '${projects.length} in progress';
    return '$ready ready · ${projects.length} total';
  }

  void _openFolder(
    String title,
    List<BusinessProfileProjectSummary> projects,
  ) {
    final ready =
        projects.where((p) => p.status == 'ready' && p.assetCount > 0).toList();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ArtifactsGridScreen(
          apiClient: widget.apiClient,
          title: title,
          projects: ready,
        ),
      ),
    );
  }
}

// (v37) the previous _ArtifactsBucket shim has been replaced by three
// top-level List<BusinessProfileProjectSummary> fields on the State.

class _FolderTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  const _FolderTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(TamivaRadii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(TamivaRadii.md),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: TamivaColors.surface,
            border: Border.all(color: TamivaColors.divider),
            borderRadius: BorderRadius.circular(TamivaRadii.md),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: TamivaColors.gold.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(TamivaRadii.sm),
                  border: Border.all(color: TamivaColors.gold.withOpacity(0.4)),
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: TamivaColors.gold),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(subtitle, style: textTheme.bodyMedium),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: TamivaColors.gold),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtifactsGridScreen extends StatelessWidget {
  final ApiClient apiClient;
  final String title;
  final List<BusinessProfileProjectSummary> projects;

  const _ArtifactsGridScreen({
    required this.apiClient,
    required this.title,
    required this.projects,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: TamivaColors.background,
      appBar: AppBar(title: Text(title)),
      body: projects.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Nothing in this folder yet.',
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium,
                ),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.95,
              ),
              itemCount: projects.length,
              itemBuilder: (_, i) {
                final p = projects[i];
                return _ArtifactTile(
                  project: p,
                  apiClient: apiClient,
                );
              },
            ),
    );
  }
}

class _ArtifactTile extends StatelessWidget {
  final BusinessProfileProjectSummary project;
  final ApiClient apiClient;

  const _ArtifactTile({
    required this.project,
    required this.apiClient,
  });

  @override
  Widget build(BuildContext context) {
    final sample = project.firstAssetUrlSample;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(TamivaRadii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(TamivaRadii.md),
        onTap: sample == null
            ? null
            : () => _openViewer(context, sample),
        child: Container(
          decoration: BoxDecoration(
            color: TamivaColors.surface,
            border: Border.all(color: TamivaColors.divider),
            borderRadius: BorderRadius.circular(TamivaRadii.md),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: sample == null
                    ? const Center(
                        child: Icon(
                          Icons.broken_image,
                          color: TamivaColors.textFaint,
                        ),
                      )
                    : NetImage(
                        imageUrl: sample,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => const Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        errorWidget: (_, __, ___) => const Center(
                          child: Icon(
                            Icons.broken_image,
                            color: TamivaColors.textFaint,
                          ),
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      project.type.toUpperCase(),
                      style: Theme.of(context)
                          .textTheme
                          .labelMedium
                          ?.copyWith(color: TamivaColors.gold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatDate(project.createdAt),
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: TamivaColors.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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

  String _formatDate(String iso) {
    if (iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final d = dt.toLocal();
    final two = (int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  void _openViewer(BuildContext context, String url) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ArtifactViewerScreen(
          imageUrl: url,
          title: project.type.toUpperCase(),
        ),
      ),
    );
  }
}

/// Minimal full-screen image viewer with a Download action in the
/// app bar and a Back button (the system back gesture still works).
class _ArtifactViewerScreen extends StatelessWidget {
  final String imageUrl;
  final String title;

  const _ArtifactViewerScreen({
    required this.imageUrl,
    required this.title,
  });

  Future<void> _download(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Saving to your gallery…'),
        duration: Duration(seconds: 1),
      ),
    );
    final result = await saveImageToGallery(imageUrl);
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(result.ok ? 'Saved to your gallery.' : result.error!),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(title),
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_rounded),
            tooltip: 'Download',
            onPressed: () => _download(context),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(TamivaRadii.md),
          child: NetImage(
            imageUrl: imageUrl,
            fit: BoxFit.contain,
            placeholder: (_, __) =>
                const Center(child: CircularProgressIndicator()),
            errorWidget: (_, __, ___) => const Center(
              child: Icon(Icons.broken_image,
                  color: TamivaColors.textFaint, size: 32),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final UserFacingError error;
  final VoidCallback onRetry;

  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined,
                color: TamivaColors.gold, size: 44),
            const SizedBox(height: 20),
            Text(
              error.title,
              textAlign: TextAlign.center,
              style: textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              error.message,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
