import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../data/brand_tones.dart';
import '../data/industries.dart';
import '../data/palette_styles.dart';
import '../data/font_pairs.dart';
import '../errors/user_facing_error.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../services/payment_service.dart';
import '../theme/tamiva_theme.dart';
import '../widgets/hero_scaffold.dart';
import '../widgets/inline_error.dart';
import '../widgets/exit_confirm_scope.dart';
import '../widgets/logout_action.dart';
import '../widgets/multi_select_sheet.dart';
import 'brand_assets_screen.dart';
import 'upload_assets_screen.dart';

class BusinessInfoScreen extends StatefulWidget {
  final ApiClient apiClient;
  final String userId;
  /// v24: tier is now passed in so the lock screen can show tier-specific
  /// copy. Tier is fetched at app boot / after login.
  final String tier;
  /// When true, this screen renders the lock UI immediately instead of
  /// fetching the existing profile. Used by welcome_screen right after
  /// login to skip the extra round-trip when we already know the user
  /// has a profile.
  final bool skipLockPrefetch;

  const BusinessInfoScreen({
    super.key,
    required this.apiClient,
    required this.userId,
    this.tier = 'free',
    this.skipLockPrefetch = false,
  });

  @override
  State<BusinessInfoScreen> createState() => _BusinessInfoScreenState();
}

class _BusinessInfoScreenState extends State<BusinessInfoScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _taglineController = TextEditingController();

  List<String> _selectedIndustries = [];
  List<String> _selectedTones = [];
  List<String> _selectedPalettes = []; // v24
  List<String> _selectedFonts = [];      // v24

  bool _submitting = false;
  bool _loading = true;
  bool _locked = false;
  String? _existingProfileId;
  // v24: tier at submit time. Pro users editing go through the PUT
  // pathway (which clears old assets), Free users go through the POST
  // pathway (which creates a new profile).
  late String _tier;

  UserFacingError? _error;

  @override
  void initState() {
    super.initState();
    _tier = widget.tier;
    if (widget.skipLockPrefetch) {
      setState(() => _loading = false);
    } else {
      _loadExistingProfile();
    }
  }

  Future<void> _loadExistingProfile() async {
    try {
      final existing = await widget.apiClient.getBusinessProfileByUser(widget.userId);
      if (!mounted) return;
      if (existing != null) {
        _existingProfileId = existing.id;
        _nameController.text = existing.name;
        _taglineController.text = existing.tagline ?? '';
        _selectedIndustries = existing.industry
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        _selectedTones = existing.tone == null
            ? const []
            : existing.tone!.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        _selectedPalettes = existing.palettePreference == null
            ? const []
            : existing.palettePreference!.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        _selectedFonts = existing.fontPreference == null
            ? const []
            : existing.fontPreference!.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        setState(() => _locked = true);
      }
    } catch (_) {
      // Best-effort fetch - default to form mode if it fails.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _taglineController.dispose();
    super.dispose();
  }

  Future<void> _pickIndustries() async {
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MultiSelectSheet(
        title: 'Pick industries',
        options: kTamivaIndustries,
        selected: _selectedIndustries,
        maxSelection: null,
      ),
    );
    if (result != null && mounted) {
      setState(() => _selectedIndustries = result);
    }
  }

  Future<void> _pickTones() async {
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MultiSelectSheet(
        title: 'Pick brand tones',
        options: kTamivaBrandTones,
        selected: _selectedTones,
        maxSelection: 2,
      ),
    );
    if (result != null && mounted) {
      setState(() => _selectedTones = result);
    }
  }

  Future<void> _pickPalettes() async {
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MultiSelectSheet(
        title: 'Pick colour palettes (max 2)',
        options: PaletteStyles.all.map((p) => p.displayName).toList(),
        selected: _selectedPalettes,
        maxSelection: 2,
        optionLeadingBuilder: (option) {
          final palette = PaletteStyles.all.firstWhere(
            (p) => p.displayName == option,
            orElse: () => PaletteStyles.warm,
          );
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final hex in palette.hexCodes)
                Container(
                  width: 22,
                  height: 22,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    color: _hexToColor(hex),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: TamivaColors.divider),
                  ),
                ),
            ],
          );
        },
      ),
    );
    if (result != null && mounted) {
      setState(() => _selectedPalettes = result);
    }
  }

  Future<void> _pickFonts() async {
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MultiSelectSheet(
        title: 'Pick typography styles (max 2)',
        options: FontPairs.all.map((p) => p.displayName).toList(),
        selected: _selectedFonts,
        maxSelection: 2,
        optionTextStyleBuilder: (option) {
          final pair = FontPairs.all.firstWhere(
            (p) => p.displayName == option,
            orElse: () => FontPairs.modernDefault,
          );
          return GoogleFonts.getFont(pair.googleFamily, fontSize: 20);
        },
      ),
    );
    if (result != null && mounted) {
      setState(() => _selectedFonts = result);
    }
  }

  Future<void> _startProCheckout() async {
    final result = await PaymentService.startProCheckout(
      api: widget.apiClient,
      userId: widget.userId,
    );
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (result.ok) {
      // Backend already flipped the tier to Pro during verification.
      setState(() {
        _tier = result.tier ?? 'pro';
        _locked = false; // unlock the form
      });
      messenger.showSnackBar(
        const SnackBar(content: Text('Upgrade successful. Edit your business.')),
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

  void _continueToBrandKit() {
    final profileId = _existingProfileId;
    if (profileId == null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => UploadAssetsPlaceholder(
            apiClient: widget.apiClient,
          ),
        ),
      );
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => BrandAssetsScreen(
          apiClient: widget.apiClient,
          businessProfileId: profileId,
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      // For a Pro user editing an existing profile, use PUT. For new
      // (Free) signups, use POST. Single code path keeps the form happy
      // either way.
      String profileId;
      if (_tier == 'pro' && _existingProfileId != null) {
        final updated = await widget.apiClient.updateBusinessProfile(
          userId: widget.userId,
          name: _nameController.text.trim(),
          industry: _selectedIndustries.join(', '),
          tagline: _taglineController.text.trim().isEmpty
              ? null
              : _taglineController.text.trim(),
          tone: _selectedTones.isEmpty ? null : _selectedTones.join(', '),
          palettePreference: _selectedPalettes.isEmpty ? null : _selectedPalettes.join(', '),
          fontPreference: _selectedFonts.isEmpty ? null : _selectedFonts.join(', '),
        );
        profileId = updated.id;
      } else {
        final profile = await widget.apiClient.createBusinessProfile(
          userId: widget.userId,
          name: _nameController.text.trim(),
          industry: _selectedIndustries.join(', '),
          tagline: _taglineController.text.trim().isEmpty
              ? null
              : _taglineController.text.trim(),
          tone: _selectedTones.isEmpty ? null : _selectedTones.join(', '),
          palettePreference: _selectedPalettes.isEmpty ? null : _selectedPalettes.join(', '),
          fontPreference: _selectedFonts.isEmpty ? null : _selectedFonts.join(', '),
        );
        profileId = profile.id;
      }

      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => UploadAssetsScreen(
            apiClient: widget.apiClient,
            businessProfileId: profileId,
          ),
        ),
      );
    } catch (e) {
      setState(() => _error = UserFacingError.from(
            e,
            operation: 'save your business',
          ));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: TamivaColors.background,
        body: Center(child: CircularProgressIndicator(color: TamivaColors.gold)),
      );
    }
    if (_locked) return _buildLockedView(context);
    return _buildForm(context);
  }

  Widget _buildLockedView(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return ExitConfirmScope(
      child: HeroBannerScaffold(
        heroAsset: 'assets/hero/business_info.png',
        title: 'About your business',
        actions: [LogoutAction(apiClient: widget.apiClient)],
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: TamivaColors.surface,
                border: Border.all(color: TamivaColors.gold),
                borderRadius: BorderRadius.circular(TamivaRadii.lg),
                boxShadow: [
                  BoxShadow(
                    color: TamivaColors.gold.withOpacity(0.18),
                    blurRadius: 32,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 72, height: 72,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: TamivaColors.gold.withOpacity(0.12),
                      shape: BoxShape.circle,
                      border: Border.all(color: TamivaColors.gold, width: 1.5),
                    ),
                    child: const Icon(Icons.lock_rounded, color: TamivaColors.gold, size: 36),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Business info locked',
                    textAlign: TextAlign.center,
                    style: textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _tier == 'pro'
                        ? 'Editing your business starts a new regeneration cycle. Pay ₹5000 to unlock editing.'
                        : "You've already set up your studio. Editing your business info is part of Tamiva Pro.",
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 28),
                  GradientCtaButton(
                    onPressed: _startProCheckout,
                    child: const Text('Upgrade to Tamiva Pro · ₹5000/mo'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _continueToBrandKit,
                    child: Text(
                      'Continue to your brand kit →',
                      style: textTheme.labelLarge?.copyWith(color: TamivaColors.gold),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return ExitConfirmScope(
      child: HeroBannerScaffold(
        heroAsset: 'assets/hero/business_info.png',
        title: 'About your business',
        actions: [LogoutAction(apiClient: widget.apiClient)],
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('STEP 1 OF 3', style: textTheme.labelMedium),
                const SizedBox(height: 8),
                Text('The basics', style: textTheme.headlineMedium),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _nameController,
                  style: textTheme.bodyLarge,
                  decoration: const InputDecoration(labelText: 'BUSINESS NAME'),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 16),
                _IndustryPicker(
                  selected: _selectedIndustries,
                  onTap: _pickIndustries,
                  onRemove: (label) =>
                      setState(() => _selectedIndustries.remove(label)),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _taglineController,
                  style: textTheme.bodyLarge,
                  decoration: const InputDecoration(labelText: 'TAGLINE (OPTIONAL)'),
                ),
                const SizedBox(height: 16),
                _TonePicker(
                  selected: _selectedTones,
                  onTap: _pickTones,
                  onRemove: (label) =>
                      setState(() => _selectedTones.remove(label)),
                ),
                const SizedBox(height: 16),
                _PalettePicker(
                  selected: _selectedPalettes,
                  onTap: _pickPalettes,
                  onRemove: (label) =>
                      setState(() => _selectedPalettes.remove(label)),
                ),
                const SizedBox(height: 16),
                _FontPicker(
                  selected: _selectedFonts,
                  onTap: _pickFonts,
                  onRemove: (label) =>
                      setState(() => _selectedFonts.remove(label)),
                ),
                const SizedBox(height: 28),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: InlineError(error: _error!),
                  ),
                GradientCtaButton(
                  loading: _submitting,
                  onPressed: _submitting ? null : _submit,
                  child: const Text('Continue  →'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder widget for the upload screen. The real
/// UploadAssetsScreen + photo upload UI lives separately. Routing
/// here skips it for now - the brand kit screen is reachable next.
class UploadAssetsPlaceholder extends StatelessWidget {
  final ApiClient apiClient;
  final String? businessProfileId;

  const UploadAssetsPlaceholder({
    super.key,
    required this.apiClient,
    this.businessProfileId,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TamivaColors.background,
      body: Center(
        child: ElevatedButton(
          onPressed: () {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => BrandAssetsScreen(
                  apiClient: apiClient,
                  businessProfileId: businessProfileId ?? '',
                ),
              ),
            );
          },
          child: const Text('Continue to brand kit'),
        ),
      ),
    );
  }
}

/// Tap-to-open chip picker. Renders selected items as chips inside a
/// bordered card with a hint when nothing's picked. Tapping anywhere
/// opens the picker modal.
class _ChipPickerCard extends StatelessWidget {
  final String label;
  final String emptyHint;
  final List<String> selected;
  final VoidCallback onTap;
  final void Function(String) onRemove;

  const _ChipPickerCard({
    required this.label,
    required this.emptyHint,
    required this.selected,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(TamivaRadii.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(TamivaRadii.sm),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0x1AD4A72C),
            border: Border.all(color: TamivaColors.divider),
            borderRadius: BorderRadius.circular(TamivaRadii.sm),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: textTheme.labelMedium),
              const SizedBox(height: 8),
              if (selected.isEmpty)
                Text(
                  emptyHint,
                  style: textTheme.bodyMedium?.copyWith(color: TamivaColors.textFaint),
                )
              else
                Wrap(
                  spacing: 6, runSpacing: 6,
                  children: selected.map((s) => _Chip(label: s, onRemove: () => onRemove(s))).toList(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;
  const _Chip({required this.label, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: TamivaColors.gold.withOpacity(0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: TamivaColors.gold.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: TamivaColors.textPrimary, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: onRemove,
            child: const Icon(Icons.close, size: 14, color: TamivaColors.gold),
          ),
        ],
      ),
    );
  }
}

class _IndustryPicker extends StatelessWidget {
  final List<String> selected;
  final VoidCallback onTap;
  final void Function(String) onRemove;
  const _IndustryPicker({required this.selected, required this.onTap, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return _ChipPickerCard(
      label: 'INDUSTRY',
      emptyHint: 'Tap to pick one or more',
      selected: selected,
      onTap: onTap,
      onRemove: onRemove,
    );
  }
}

class _TonePicker extends StatelessWidget {
  final List<String> selected;
  final VoidCallback onTap;
  final void Function(String) onRemove;
  const _TonePicker({required this.selected, required this.onTap, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return _ChipPickerCard(
      label: 'BRAND TONE (MAX 2)',
      emptyHint: 'Tap to pick one or two tones',
      selected: selected,
      onTap: onTap,
      onRemove: onRemove,
    );
  }
}

class _PalettePicker extends StatelessWidget {
  final List<String> selected;
  final VoidCallback onTap;
  final void Function(String) onRemove;
  const _PalettePicker({required this.selected, required this.onTap, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return _ChipPickerCard(
      label: 'COLOUR PALETTE (MAX 2)',
      emptyHint: 'Tap to pick one or two palettes',
      selected: selected,
      onTap: onTap,
      onRemove: onRemove,
    );
  }
}

class _FontPicker extends StatelessWidget {
  final List<String> selected;
  final VoidCallback onTap;
  final void Function(String) onRemove;
  const _FontPicker({required this.selected, required this.onTap, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return _ChipPickerCard(
      label: 'TYPOGRAPHY STYLE (MAX 2)',
      emptyHint: 'Tap to pick one or two styles',
      selected: selected,
      onTap: onTap,
      onRemove: onRemove,
    );
  }
}

/// Parses a `#RRGGBB` hex string into an opaque [Color]. Falls back to
/// a faint colour if the string can't be parsed.
Color _hexToColor(String hex) {
  final cleaned = hex.replaceFirst('#', '');
  final value = int.tryParse('FF$cleaned', radix: 16);
  return value == null ? TamivaColors.textFaint : Color(value);
}
