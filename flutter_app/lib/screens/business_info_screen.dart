import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../data/brand_tones.dart';
import '../data/industries.dart';
import '../data/palette_styles.dart';
import '../data/font_pairs.dart';
import '../errors/user_facing_error.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../services/draft_store.dart';
import '../theme/tamiva_theme.dart';
import '../widgets/hero_scaffold.dart';
import '../widgets/inline_error.dart';
import '../widgets/exit_confirm_scope.dart';
import '../widgets/logout_action.dart';
import '../widgets/multi_select_sheet.dart';
import 'brand_assets_screen.dart';
import 'pricing_screen.dart';
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

  // v38 stepper UX: scrollable form with anchored rows so the auto-
  // advance flow can scroll each subsequent picker into view after the
  // user picks in the previous one.
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _toneRowKey = GlobalKey();
  final GlobalKey _typographyRowKey = GlobalKey();
  final GlobalKey _paletteRowKey = GlobalKey();

  bool _submitting = false;
  bool _loading = true;
  bool _locked = false;
  String? _existingProfileId;
  // v24: tier at submit time. Paid users (any non-free plan) editing
  // go through the PUT pathway (which clears old assets), Free users
  // go through the POST pathway (which creates a new profile).
  late String _tier;

  /// v37: any paid tier unlocks the editing flow.
  bool get _isPaid => _tier != 'free' && _tier.isNotEmpty;

  /// v39: Continue button only appears once the user has picked a
  /// colour palette — the last step in the auto-advance chain.
  /// Industry → Brand Tone → Typography → Palette → Continue.
  bool get _canContinue => _selectedPalettes.isNotEmpty;

  UserFacingError? _error;

  // v36 / S2.12 — draft restore + auto-save.
  Timer? _draftSaveDebouncer;
  // v36 / S3.18 — stable per-submit idempotency key.
  String? _submitIdempotencyKey;

  @override
  void initState() {
    super.initState();
    _tier = widget.tier;
    if (widget.skipLockPrefetch) {
      setState(() => _loading = false);
    } else {
      _loadExistingProfile();
    }
    _restoreDraft();
    _nameController.addListener(_scheduleDraftSave);
    _taglineController.addListener(_scheduleDraftSave);
  }

  Future<void> _restoreDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final draft = DraftStore(prefs).loadBusinessInfo();
      if (!mounted || draft.isEmpty) return;
      _nameController.text = draft.name;
      _taglineController.text = draft.tagline;
      _selectedIndustries = List.of(draft.industries);
      _selectedTones = List.of(draft.tones);
      _selectedPalettes = List.of(draft.palettes);
      _selectedFonts = List.of(draft.fonts);
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Brought back your draft from last time.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (_) {
      // best-effort
    }
  }

  void _scheduleDraftSave() {
    _draftSaveDebouncer?.cancel();
    _draftSaveDebouncer =
        Timer(const Duration(milliseconds: 400), _saveDraftNow);
  }

  Future<void> _saveDraftNow() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await DraftStore(prefs).saveBusinessInfo(
        BusinessInfoDraft(
          name: _nameController.text,
          tagline: _taglineController.text,
          industries: List.of(_selectedIndustries),
          tones: List.of(_selectedTones),
          palettes: List.of(_selectedPalettes),
          fonts: List.of(_selectedFonts),
        ),
      );
    } catch (_) {}
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
    _draftSaveDebouncer?.cancel();
    _scrollController.dispose();
    _nameController.removeListener(_scheduleDraftSave);
    _taglineController.removeListener(_scheduleDraftSave);
    _nameController.dispose();
    _taglineController.dispose();
    super.dispose();
  }

  /// Scroll the row identified by [key] into view after the bottom
  /// sheet closes. Brief delay so the sheet's pop animation finishes
  /// first; without it the scroll-to-renderable can target stale
  /// layout positions.
  void _advanceToStep(GlobalKey key) {
    if (!mounted) return;
    Future.delayed(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      final ctx = key.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        alignment: 0.2,
      );
    });
  }

  Future<void> _pickIndustries() async {
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MultiSelectSheet(
        title: 'Pick an industry',
        options: kTamivaIndustries,
        selected: _selectedIndustries,
        // v37.1: single-select - the studio treats industry as a
        // single defining category, so pick one.
        maxSelection: 1,
        // Stepper UX: tap a radio → sheet pops itself → we scroll the
        // Brand Tone row into view below.
        autoDismissOnSelect: true,
      ),
    );
    if (result != null && mounted) {
      setState(() => _selectedIndustries = result);
      _scheduleDraftSave();
      _advanceToStep(_toneRowKey);
    }
  }

  Future<void> _pickTones() async {
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MultiSelectSheet(
        title: 'Pick a brand tone',
        options: kTamivaBrandTones,
        selected: _selectedTones,
        // v37.1: single-select - one tone reads cleaner than a blend
        // across the brand kit (logo, carousel, film).
        maxSelection: 1,
        autoDismissOnSelect: true,
      ),
    );
    if (result != null && mounted) {
      setState(() => _selectedTones = result);
      _scheduleDraftSave();
      _advanceToStep(_typographyRowKey);
    }
  }

  Future<void> _pickPalettes() async {
    // Send palette KEYS (e.g. "warm") — not displayNames ("Warm (maroon +
    // ember + gold)") — so the backend PALETTE_HEX map can resolve them.
    // The displayName was unsplittable on the server, so any palette
    // beyond the original 6 silently fell back to warm.
    final selectedKeys = _selectedPalettes
        .map((k) => PaletteStyles.byKey(k).key)
        .toList();
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MultiSelectSheet(
        title: 'Pick a colour palette',
        options: PaletteStyles.all.map((p) => p.displayName).toList(),
        selected: selectedKeys
            .map((k) =>
                PaletteStyles.byKey(k).displayName)
            .toList(),
        maxSelection: 1,
        // v39: palette is the last step in the auto-advance chain
        // (after typography). Tapping a swatch pops the sheet; the
        // Continue button then reveals itself at the bottom because
        // _canContinue becomes true. No further _advanceToStep call
        // — there is no row after palette to scroll to.
        autoDismissOnSelect: true,
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
      // Resolve displayNames back to keys for storage.
      final resolved = result
          .map((dn) => PaletteStyles.all
              .firstWhere(
                (p) => p.displayName == dn,
                orElse: () => PaletteStyles.warm,
              )
              .key)
          .toList();
      setState(() => _selectedPalettes = resolved);
      _scheduleDraftSave();
    }
  }

  Future<void> _pickFonts() async {
    // Send font KEYS (e.g. "editorial") — not displayNames ("Editorial").
    // The backend FONT_CATEGORY_DESC map can then resolve them; any font
    // beyond the original 6 would otherwise fall back to modern_default.
    final selectedKeys = _selectedFonts
        .map((k) => FontPairs.byKey(k).key)
        .toList();
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MultiSelectSheet(
        title: 'Pick a typography style',
        options: FontPairs.all.map((p) => p.displayName).toList(),
        selected: selectedKeys
            .map((k) => FontPairs.byKey(k).displayName)
            .toList(),
        maxSelection: 1,
        // v39: typography now advances into the palette step.
        autoDismissOnSelect: true,
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
      final resolved = result
          .map((dn) => FontPairs.all
              .firstWhere(
                (p) => p.displayName == dn,
                orElse: () => FontPairs.modernDefault,
              )
              .key)
          .toList();
      setState(() => _selectedFonts = resolved);
      _scheduleDraftSave();
      _advanceToStep(_paletteRowKey);
    }
  }

  // v37: the locked view now opens the Pricing screen via a fresh
// navigation in the build method below; _startProCheckout is no
// longer used in this file.

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
    // v36 / S3.18 — stable idempotency key for retries within this submit.
    _submitIdempotencyKey = const Uuid().v4();
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      // For a paid user editing an existing profile, use PUT. For new
      // (Free) signups, use POST. Single code path keeps the form happy
      // either way.
      String profileId;
      if (_isPaid && _existingProfileId != null) {
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
          idempotencyKey: _submitIdempotencyKey,
        );
        profileId = profile.id;
      }

      // v36 / S2.12 — clear the draft on successful submit.
      try {
        final prefs = await SharedPreferences.getInstance();
        await DraftStore(prefs).clearBusinessInfo();
      } catch (_) {}

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
                    _isPaid
                        ? 'Editing your business starts a new regeneration cycle. Pick a plan to unlock editing.'
                        : "You've already set up your studio. Editing your business info is part of a paid plan.",
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 28),
                  GradientCtaButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PricingScreen(
                            apiClient: widget.apiClient,
                          ),
                        ),
                      );
                    },
                    child: const Text('Choose a plan'),
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
        body: Form(
          key: _formKey,
          child: ListView(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
            children: [
              Text('STEP 1 OF 3', style: textTheme.labelMedium),
              const SizedBox(height: 8),
              Text('The basics', style: textTheme.headlineMedium),
              const SizedBox(height: 24),

              // 1. Business name — required, blocks submit if empty.
              TextFormField(
                controller: _nameController,
                style: textTheme.bodyLarge,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'BUSINESS NAME'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Enter your business name to continue' : null,
              ),
              const SizedBox(height: 16),

              // 2. Tagline — optional, just flows below the name.
              TextFormField(
                controller: _taglineController,
                style: textTheme.bodyLarge,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(labelText: 'TAGLINE (OPTIONAL)'),
              ),
              const SizedBox(height: 16),

              // 3. Industry — auto-advances to Brand Tone on selection.
              _IndustryPicker(
                selected: _selectedIndustries,
                onTap: _pickIndustries,
                onRemove: (label) =>
                    setState(() => _selectedIndustries.remove(label)),
              ),
              const SizedBox(height: 16),

              // 4. Brand tone — anchored so the auto-advance can scroll
              //    it into view after Industry is picked.
              Container(
                key: _toneRowKey,
                child: _TonePicker(
                  selected: _selectedTones,
                  onTap: _pickTones,
                  onRemove: (label) =>
                      setState(() => _selectedTones.remove(label)),
                ),
              ),
              const SizedBox(height: 16),

              // 5. Typography — anchored so auto-advance can scroll it into
              //    view after Brand Tone is picked. Advances into the
              //    palette step on selection (v39).
              Container(
                key: _typographyRowKey,
                child: _FontPicker(
                  selected: _selectedFonts,
                  onTap: _pickFonts,
                  onRemove: (label) =>
                      setState(() => _selectedFonts.remove(label)),
                ),
              ),
              const SizedBox(height: 16),

              // 6. Palette — anchored so the typography → palette auto-
              //    advance can scroll it into view. After this pick,
              //    Continue reveals itself (see _canContinue).
              Container(
                key: _paletteRowKey,
                child: _PalettePicker(
                  selected: _selectedPalettes,
                  onTap: _pickPalettes,
                  onRemove: (label) =>
                      setState(() => _selectedPalettes.remove(label)),
                ),
              ),
              const SizedBox(height: 28),

              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: InlineError(error: _error!),
                ),

              // 7. Continue button — only revealed once Palette has been picked.
              //    Before that, show a small hint so the user understands
              //    what unlocks the button.
              if (_canContinue) ...[
                GradientCtaButton(
                  loading: _submitting,
                  onPressed: _submitting ? null : _submit,
                  child: const Text('Continue  →'),
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Pick a colour palette to continue',
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall?.copyWith(
                      color: TamivaColors.textFaint,
                    ),
                  ),
                ),
            ],
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
            style: const TextStyle(
              fontSize: 12,
              color: TamivaColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
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

/// Industry picker that participates in form validation. Wrapped in a
/// [FormField] so `_formKey.currentState.validate()` covers the picker
/// alongside the [TextFormField]s in this form. Empty selection →
/// inline "Pick your industry to continue" error rendered under the
/// card. Tapping a chip to remove, or opening the sheet and picking
/// afresh, calls `field.didChange(...)` so the validator re-runs
/// immediately and clears the error as soon as a real selection exists.
///
/// Stateful so we can mirror the parent's [selected] list into the
/// FormField whenever it changes (e.g. after the bottom sheet closes
/// and the parent calls `setState(() => _selectedIndustries = result)`).
class _IndustryPicker extends StatefulWidget {
  final List<String> selected;
  final VoidCallback onTap;
  final void Function(String) onRemove;
  const _IndustryPicker({
    required this.selected,
    required this.onTap,
    required this.onRemove,
  });

  @override
  State<_IndustryPicker> createState() => _IndustryPickerState();
}

class _IndustryPickerState extends State<_IndustryPicker> {
  final GlobalKey<FormFieldState<List<String>>> _fieldKey =
      GlobalKey<FormFieldState<List<String>>>();

  @override
  void didUpdateWidget(covariant _IndustryPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Whenever the parent hands us a new selection (e.g. the user just
    // picked one in the bottom sheet), push it into the FormField so
    // the validator sees the fresh value and the error clears.
    if (!_listEq(oldWidget.selected, widget.selected)) {
      _fieldKey.currentState?.didChange(List<String>.of(widget.selected));
    }
  }

  static bool _listEq(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return FormField<List<String>>(
      key: _fieldKey,
      initialValue: List<String>.of(widget.selected),
      validator: (value) =>
          (value == null || value.isEmpty) ? 'Pick your industry to continue' : null,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      builder: (field) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ChipPickerCard(
              label: 'INDUSTRY',
              emptyHint: 'Tap to pick one',
              selected: widget.selected,
              onTap: widget.onTap,
              onRemove: widget.onRemove,
            ),
            if (field.hasError)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Text(
                  field.errorText ?? '',
                  style: Theme.of(field.context).textTheme.bodySmall?.copyWith(
                        color: TamivaColors.error,
                      ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _TonePicker extends StatelessWidget {
  final List<String> selected;
  final VoidCallback onTap;
  final void Function(String) onRemove;
  const _TonePicker({
    required this.selected,
    required this.onTap,
    required this.onRemove,
  });

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
  const _PalettePicker({
    required this.selected,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return _ChipPickerCard(
      label: 'COLOUR PALETTE (PICK 1)',
      emptyHint: 'Tap to pick a palette',
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
  const _FontPicker({
    required this.selected,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return _ChipPickerCard(
      label: 'TYPOGRAPHY STYLE (PICK 1)',
      emptyHint: 'Tap to pick a style',
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
