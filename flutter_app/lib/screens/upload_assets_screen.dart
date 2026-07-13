import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../errors/user_facing_error.dart';
import '../services/api_client.dart';
import '../theme/tamiva_theme.dart';
import '../widgets/hero_scaffold.dart';
import '../widgets/inline_error.dart';
import '../widgets/logout_action.dart';
import 'brand_assets_screen.dart';

/// Reference asset upload step. Users can add any combination of:
///   1. Existing brand logo (if they have one)
///   2. Brand ambassador photos (character-lock reference)
///   3. Product photos
///   4. Any other reference images
///
/// Everything is optional and gallery-only (per product spec). The
/// backend receives all photos through the existing ambassador photo
/// route, tagged with a source label so we can differentiate later.
class UploadAssetsScreen extends StatefulWidget {
  final ApiClient apiClient;
  final String businessProfileId;

  const UploadAssetsScreen({
    super.key,
    required this.apiClient,
    required this.businessProfileId,
  });

  @override
  State<UploadAssetsScreen> createState() => _UploadAssetsScreenState();
}

class _UploadAssetsScreenState extends State<UploadAssetsScreen> {
  final _picker = ImagePicker();

  // Each category holds a list of XFile photos the user picked. All are
  // optional; empty lists mean "skip this category".
  final Map<_AssetCategory, List<XFile>> _photos = {
    _AssetCategory.logo: [],
    _AssetCategory.ambassador: [],
    _AssetCategory.product: [],
    _AssetCategory.other: [],
  };

  bool _submitting = false;
  UserFacingError? _error;

  Future<void> _addPhotos(_AssetCategory category) async {
    final currentCount = _photos[category]!.length;
    final max = category.maxPhotos;
    final remaining = max - currentCount;

    if (remaining <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${category.title} allows up to $max photo${max == 1 ? '' : 's'}'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    // pickMultiImage with a limit (Android 13+) - falls back to picking
    // any count on older devices, in which case we trim client-side.
    final picked = await _picker.pickMultiImage(
      imageQuality: 90,
      limit: remaining,
    );
    if (picked.isEmpty) return;

    final toAdd = picked.take(remaining).toList();
    setState(() {
      _photos[category]!.addAll(toAdd);
    });

    if (picked.length > remaining) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Kept the first $remaining. ${category.title} max is $max.'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _removePhoto(_AssetCategory category, int index) {
    setState(() {
      _photos[category]!.removeAt(index);
    });
  }

  bool get _hasAnyPhotos => _photos.values.any((list) => list.isNotEmpty);

  Future<void> _continue({required bool skip}) async {
    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      if (!skip && _hasAnyPhotos) {
        // v36 / S2.14 — per-file upload with retry. Each file is
        // uploaded independently with a 2-attempt retry on transient
        // failures; per-file status is tracked so one bad photo no
        // longer fails the whole batch.
        final uploadedUrls = <String>[];
        final labels = <String>[];
        final failed = <String>[];

        for (final category in _photos.keys) {
          for (var i = 0; i < _photos[category]!.length; i++) {
            final photo = _photos[category]![i];
            final label = '${category.label} ${i + 1}';
            final valid = await _validatePhotoFile(photo.path);
            if (valid != null) {
              failed.add('$label: $valid');
              continue;
            }
            try {
              final url = await _uploadWithRetry(photo.path);
              uploadedUrls.add(url);
              labels.add(label);
            } catch (e) {
              failed.add('$label: ${_uploadErrorMessage(e)}');
            }
          }
        }

        if (uploadedUrls.isNotEmpty) {
          await widget.apiClient.addAmbassadorPhotos(
            businessProfileId: widget.businessProfileId,
            photoUrls: uploadedUrls,
            angleLabels: labels,
          );
        }

        if (failed.isNotEmpty && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                failed.length == 1
                    ? failed.first
                    : '${failed.length} photos failed. The others were uploaded — you can retry the failed ones later.',
              ),
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }

      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => BrandAssetsScreen(
            apiClient: widget.apiClient,
            businessProfileId: widget.businessProfileId,
          ),
        ),
      );
    } catch (e) {
      setState(() => _error = UserFacingError.from(e, operation: "upload your photos"));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// v36 / S3.19 — client-side validation. Returns null on success or
  /// a short, user-facing message on rejection.
  Future<String?> _validatePhotoFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return 'File missing.';
      final size = await file.length();
      if (size == 0) return 'That file is empty.';
      if (size > 12 * 1024 * 1024) {
        return 'File is too large (max 12 MB).';
      }
      final ext = path.toLowerCase();
      if (ext.endsWith('.heic') || ext.endsWith('.heif')) {
        return 'HEIC not supported. Convert to JPG or PNG.';
      }
      if (ext.endsWith('.pdf') ||
          ext.endsWith('.doc') ||
          ext.endsWith('.docx') ||
          ext.endsWith('.txt')) {
        return 'Documents aren\'t supported. Pick a JPG or PNG.';
      }
      return null;
    } catch (_) {
      return 'That file couldn\'t be read.';
    }
  }

  /// v36 / S2.14 — upload with retry. Two attempts total; transient
  /// failures retry once. 4xx validation surfaces immediately.
  Future<String> _uploadWithRetry(String path) async {
    const maxAttempts = 2;
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await widget.apiClient.uploadPhoto(path);
      } catch (e) {
        lastError = e;
        if (!_isTransient(e) || attempt == maxAttempts) rethrow;
        await Future.delayed(Duration(milliseconds: 400 * attempt));
      }
    }
    throw lastError ?? Exception('Upload failed.');
  }

  bool _isTransient(Object error) {
    if (error is ApiException) {
      return error.statusCode >= 500 || error.statusCode == 408;
    }
    return error.toString().toLowerCase().contains('timeout') ||
        error.toString().toLowerCase().contains('socket');
  }

  String _uploadErrorMessage(Object error) {
    if (error is ApiException) {
      try {
        final j = jsonDecode(error.body);
        if (j is Map && j['error'] is String) return j['error'] as String;
      } catch (_) {}
    }
    return "Couldn\'t upload that photo.";
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return HeroBannerScaffold(
      heroAsset: 'assets/hero/ambassador.png',
      title: 'Upload your assets',
      actions: [LogoutAction(apiClient: widget.apiClient)],
      bottomBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: (_submitting || _hasAnyPhotos)
                      ? null
                      : () => _continue(skip: true),
                  child: const Text('Skip for now'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GradientCtaButton(
                  loading: _submitting,
                  onPressed: _submitting ? null : () => _continue(skip: false),
                  child: const Text('Continue  →'),
                ),
              ),
            ],
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('STEP 2 OF 3', style: textTheme.labelMedium),
            const SizedBox(height: 8),
            Text('Reference material', style: textTheme.headlineMedium),
            const SizedBox(height: 12),
            Text(
              'All optional. Add anything you already have and skip the rest. '
              'The more you share, the more your generated assets look like you.',
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            for (final category in _AssetCategory.values) ...[
              _UploadCard(
                category: category,
                photos: _photos[category]!,
                onAdd: () => _addPhotos(category),
                onRemove: (i) => _removePhoto(category, i),
              ),
              const SizedBox(height: 12),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: InlineError(error: _error!),
              ),
          ],
        ),
      ),
    );
  }
}

enum _AssetCategory { logo, ambassador, product, other }

extension on _AssetCategory {
  String get label {
    switch (this) {
      case _AssetCategory.logo:
        return 'Logo';
      case _AssetCategory.ambassador:
        return 'Ambassador';
      case _AssetCategory.product:
        return 'Product';
      case _AssetCategory.other:
        return 'Other';
    }
  }

  String get title {
    switch (this) {
      case _AssetCategory.logo:
        return 'Existing logo';
      case _AssetCategory.ambassador:
        return 'Brand ambassador';
      case _AssetCategory.product:
        return 'Product photos';
      case _AssetCategory.other:
        return 'Other references';
    }
  }

  int get maxPhotos {
    switch (this) {
      case _AssetCategory.logo:
        return 1;
      case _AssetCategory.ambassador:
        return 1;
      case _AssetCategory.product:
        return 5;
      case _AssetCategory.other:
        return 2;
    }
  }

  String get subtitle {
    switch (this) {
      case _AssetCategory.logo:
        return 'If you already have one · 1 photo';
      case _AssetCategory.ambassador:
        return 'A clear, well-lit portrait · 1 photo';
      case _AssetCategory.product:
        return 'Show us what you sell · up to 5';
      case _AssetCategory.other:
        return 'Inspiration, mood boards · up to 2';
    }
  }

  IconData get icon {
    switch (this) {
      case _AssetCategory.logo:
        return Icons.auto_awesome_outlined;
      case _AssetCategory.ambassador:
        return Icons.person_outline;
      case _AssetCategory.product:
        return Icons.shopping_bag_outlined;
      case _AssetCategory.other:
        return Icons.image_outlined;
    }
  }
}

class _UploadCard extends StatelessWidget {
  final _AssetCategory category;
  final List<XFile> photos;
  final VoidCallback onAdd;
  final void Function(int) onRemove;

  const _UploadCard({
    required this.category,
    required this.photos,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TamivaColors.surface,
        border: Border.all(color: TamivaColors.divider),
        borderRadius: BorderRadius.circular(TamivaRadii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0x33D4A72C),
                  borderRadius: BorderRadius.circular(TamivaRadii.sm),
                ),
                child: Icon(category.icon, color: TamivaColors.gold, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(category.title, style: textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(category.subtitle, style: textTheme.bodyMedium),
                  ],
                ),
              ),
              Text(
                'Optional',
                style: textTheme.labelMedium?.copyWith(
                  color: TamivaColors.textFaint,
                  letterSpacing: 1.2,
                  fontSize: 10,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Photo thumbnails + "+ Add" tile
          SizedBox(
            height: 80,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: photos.length + (photos.length < category.maxPhotos ? 1 : 0),
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                if (i == photos.length) {
                  return InkWell(
                    onTap: onAdd,
                    borderRadius: BorderRadius.circular(TamivaRadii.sm),
                    child: Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: TamivaColors.gold.withOpacity(0.5),
                          style: BorderStyle.solid,
                        ),
                        borderRadius: BorderRadius.circular(TamivaRadii.sm),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_photo_alternate_outlined,
                              color: TamivaColors.gold, size: 22),
                          SizedBox(height: 4),
                          Text('Add',
                              style: TextStyle(
                                  color: TamivaColors.gold,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  );
                }
                return Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(TamivaRadii.sm),
                      child: Image.file(
                        File(photos[i].path),
                        width: 80,
                        height: 80,
                        fit: BoxFit.cover,
                      ),
                    ),
                    Positioned(
                      right: 2,
                      top: 2,
                      child: GestureDetector(
                        onTap: () => onRemove(i),
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(
                            color: Colors.black87,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close, size: 14, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
