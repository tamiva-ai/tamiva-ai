import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, HttpException;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../errors/user_facing_error.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../services/auth_state.dart';
import '../theme/tamiva_theme.dart';
import '../widgets/hero_scaffold.dart';
import '../widgets/inline_error.dart';
import '../widgets/exit_confirm_scope.dart';
import '../widgets/password_field.dart';
import 'business_info_screen.dart';
import 'brand_assets_screen.dart';
import 'forgot_password_screen.dart';

/// Combined sign-in / sign-up screen. Default mode is Sign In (the
/// common case for returning users); tap the "Sign up" pill to flip to
/// the full registration form.
///
/// Both modes share the same brand chrome (logo, eyebrow, capability
/// chips, IG footer) and the same submit pattern: validate, then either
/// login() or signup() on the API client, then route to the next step.
class WelcomeScreen extends StatefulWidget {
  final ApiClient apiClient;
  final bool startInSignUpMode;

  const WelcomeScreen({
    super.key,
    required this.apiClient,
    this.startInSignUpMode = false,
  });

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _submitting = false;
  bool _signUpMode = false;
  UserFacingError? _error;

  // v36 / S3.18 — stable per-submit idempotency key.
  String? _signupIdempotencyKey;
  static const _uuid = Uuid();

  // v36 / S1.2 — global session-expired listener.
  StreamSubscription<SessionEvent>? _sessionSub;

  @override
  void initState() {
    super.initState();
    _signUpMode = widget.startInSignUpMode;
    _sessionSub = SessionEvents.stream.listen((evt) async {
      if (!mounted) return;
      if (evt is SessionExpired) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Your session ended. Please sign in again.'),
          ),
        );
        try {
          final prefs = await SharedPreferences.getInstance();
          await AuthState(prefs).clear();
        } catch (_) {}
      }
    });
  }

  @override
  void dispose() {
    _sessionSub?.cancel();
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String get _formattedPhone {
    final raw = _phoneController.text.trim();
    if (raw.startsWith('+')) return raw;
    return '+91$raw';
  }

  void _setMode(bool signUp) {
    if (_signUpMode == signUp) return;
    setState(() {
      _signUpMode = signUp;
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    // v36 / S3.18 — stable idempotency key per submit attempt.
    _signupIdempotencyKey = _uuid.v4();
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      if (_signUpMode) {
        await _doSignup();
      } else {
        await _doSignIn();
      }
    } catch (e) {
      // Sign-up only: if the backend says the email/mobile is already
      // registered, surface the dedicated dialog (with the canonical
      // "Account already exists" title + reset-password/sign-in
      // actions) instead of the generic inline error. Login has its
      // own copy on the inline path because "wrong password" deserves
      // a single inline retry hint, not a popup.
      if (_signUpMode && e is ApiException) {
        final body = _extractApiMessage(e) ?? e.body;
        if (_looksLikeAlreadyRegistered(body)) {
          await _showAlreadyRegisteredDialog(body);
          return;
        }
      }
      if (mounted) setState(() => _error = _formatAuthError(e, _signUpMode));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// True when a backend message (or raw JSON body) indicates the user
  /// already has an account. Sign-up-only check — login never reaches
  /// here.
  bool _looksLikeAlreadyRegistered(String message) {
    final lower = message.toLowerCase();
    return lower.contains('already registered') ||
        lower.contains('already has a studio') ||
        lower.contains('already exists');
  }

  /// Build a friendly error for the auth surface.
  ///
  /// v37: We intentionally avoid the "Studio hiccup" title from
  /// [UserFacingError.from] here. That title sounds like a transient
  /// infra stall, but most signup failures are permanent (duplicate
  /// email caught server-side, validation mismatch the local checks
  /// missed, etc.) and the user needs to either edit their details or
  /// contact support — not wait it out.
  ///
  /// When the backend gives us a useful error message via the JSON
  /// body (now standard thanks to the v37 Express error handler in
  /// `backend/src/index.ts`), we trust it and surface it with a calmer
  /// title. When we don't have a usable message, we fall back to a
  /// generic action-oriented prompt.
  UserFacingError _formatAuthError(Object error, bool isSignUp) {
    final defaultOp = isSignUp ? 'create your account' : 'sign you in';

    // Network / offline / timeout — those genuinely are transient, so
    // keep the original copy.
    if (error is SocketException ||
        error is HttpException ||
        error is TimeoutException) {
      return UserFacingError.from(error, operation: defaultOp);
    }

    // Backend returned a structured error. Whatever message the server
    // sent is more useful than any client-side guess, so use it.
    if (error is ApiException) {
      final apiError = UserFacingError.from(error, operation: defaultOp);
      final backendMessage = _extractApiMessage(error);
      final friendlyTitle = isSignUp
          ? "We couldn't create your account"
          : "We couldn't sign you in";
      // The generic copy from UserFacingError.from isn't great for
      // auth — replace the title with our own, and prefer the
      // backend's actual reason over the canned "try again" line.
      if (backendMessage != null && backendMessage.isNotEmpty) {
        return UserFacingError(
          title: friendlyTitle,
          message: backendMessage,
          retryLabel: 'Try again',
        );
      }
      // No usable backend message. Keep apiError but strip the
      // "Studio hiccup" / "usually clears in a few seconds" framing
      // when it slipped through.
      if (apiError.title == 'Studio hiccup' ||
          apiError.message.contains('usually clears in a few seconds')) {
        return UserFacingError(
          title: friendlyTitle,
          message: 'Something went wrong on our end. '
              'Check your details and try again. If it keeps happening, '
              'our support team can help.',
          retryLabel: 'Try again',
        );
      }
      return apiError;
    }

    // Anything else (FormatException from a malformed body, generic
    // Exception, etc.) — fall back to a calm, action-oriented prompt.
    return UserFacingError(
      title: isSignUp
          ? "We couldn't create your account"
          : "We couldn't sign you in",
      message: 'Check your details and try again. '
          'If it keeps happening, our support team can help.',
      retryLabel: 'Try again',
    );
  }

  /// Read the JSON `{ "error": "..." }` body from an [ApiException].
  /// Returns null if the body isn't a parseable JSON envelope or the
  /// message is the default Express fallback ("Internal server error"),
  /// which we don't want to leak to users verbatim.
  String? _extractApiMessage(ApiException e) {
    try {
      final decoded = jsonDecode(e.body);
      if (decoded is Map && decoded['error'] is String) {
        final msg = (decoded['error'] as String).trim();
        // Skip the default Express fallback so we don't show
        // "Internal server error" — that's a server-side message, not
        // user-facing copy.
        if (msg.isEmpty || msg == 'Internal server error') return null;
        // Guard against backend leaking stack traces or internals.
        if (msg.length < 200 && !msg.contains('at ')) return msg;
      }
    } catch (_) {}
    return null;
  }

  /// Returns the User on success, throws on failure (caller surfaces
  /// 409 via the "already registered" dialog below).
  Future<User> _callSignup() {
    return widget.apiClient.signup(
      fullName: _nameController.text.trim(),
      phone: _formattedPhone,
      email: _emailController.text.trim(),
      password: _passwordController.text,
      idempotencyKey: _signupIdempotencyKey,
    );
  }

  Future<void> _doSignup() async {
    late final User user;
    try {
      user = await _callSignup();
    } on ApiException catch (e) {
      // Route the dedicated "Account already exists" dialog if the body
      // text suggests a duplicate, regardless of the HTTP status code.
      // Backend sometimes returns 409, sometimes 400 with a body that
      // still contains "already has a studio" / "already registered" —
      // either way the user needs the dialog, not the inline error.
      if (mounted && _looksLikeAlreadyRegistered(_extractApiMessage(e) ?? e.body)) {
        await _showAlreadyRegisteredDialog(e.body);
        return;
      }
      rethrow;
    }
    if (!mounted) return;
    // v36 / S2.8 — persist the validated session for cold-start auto-login.
    try {
      final prefs = await SharedPreferences.getInstance();
      await AuthState(prefs).saveUser(user);
      widget.apiClient.setUserId(user.id);
    } catch (_) {}
    await _routeAfterAuth(user);
  }

  /// Decide where to send the user after they sign up or log in.
  /// New users go through BusinessInfoScreen. Returning users (already
  /// have a BusinessProfile) skip directly to BrandAssetsScreen since
  /// business info is locked once submitted (Pro feature).
  Future<void> _routeAfterAuth(User user) async {
    try {
      final existing = await widget.apiClient.getBusinessProfileByUser(user.id);
      if (!mounted) return;
      if (existing != null) {
        // Returning user with a profile - skip straight to brand kit.
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => BrandAssetsScreen(
              apiClient: widget.apiClient,
              businessProfileId: existing.id,
            ),
          ),
        );
        return;
      }
    } catch (_) {
      // Profile lookup failed (network blip, etc). Default to showing
      // the form - the screen itself will show the lock if a profile
      // actually exists, so worst case the user sees an extra screen.
    }
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BusinessInfoScreen(
          apiClient: widget.apiClient,
          userId: user.id,
          tier: user.tier,
          skipLockPrefetch: user.isPaid,
        ),
      ),
    );
  }

  Future<void> _showAlreadyRegisteredDialog(String body) async {
    // For an email collision we surface the canonical "would you like to
    // reset your password?" prompt. For a phone collision we keep the
    // existing behaviour (sign in instead) since there's no password
    // flow tied to phone.
    final lower = body.toLowerCase();
    final isEmail = lower.contains('email');
    final isPhone = lower.contains('phone') || lower.contains('mobile');
    if (!mounted) return;

    if (isEmail) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: TamivaColors.surfaceRaised,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(TamivaRadii.md),
            side: const BorderSide(color: TamivaColors.divider),
          ),
          title: Text('Account already exists',
              style: Theme.of(ctx).textTheme.titleLarge),
          content: Text(
            'This email is already registered. Would you like to reset your password?',
            style: Theme.of(ctx).textTheme.bodyMedium,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ForgotPasswordScreen(
                      apiClient: widget.apiClient,
                      prefillEmail: _emailController.text.trim(),
                    ),
                  ),
                );
              },
              child: const Text('Reset password'),
            ),
          ],
        ),
      );
      return;
    }

    final subject = isPhone ? 'mobile number' : 'account';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TamivaColors.surfaceRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TamivaRadii.md),
          side: const BorderSide(color: TamivaColors.divider),
        ),
        title: Text('Account already exists',
            style: Theme.of(ctx).textTheme.titleLarge),
        content: Text(
          'This $subject is already registered. Sign in to pick up where you left off.',
          style: Theme.of(ctx).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _setMode(false);
            },
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
  }

  Future<void> _doSignIn() async {
    final user = await widget.apiClient.login(
      email: _emailController.text.trim(),
      password: _passwordController.text,
    );
    if (!mounted) return;
    // v36 / S2.8 — persist the validated session.
    try {
      final prefs = await SharedPreferences.getInstance();
      await AuthState(prefs).saveUser(user);
      widget.apiClient.setUserId(user.id);
    } catch (_) {}
    await _routeAfterAuth(user);
  }

  Future<void> _launchInstagram() async {
    final uri = Uri.parse('https://instagram.com/tamiva.media');
    try {
      // Try external app first (Instagram's actual app, then browser).
      // launchUrl returns false if no handler is registered; we don't
      // care - try the platform-default launch mode and surface any
      // real error so the user gets a SnackBar instead of silent failure.
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open Instagram. Please visit instagram.com/tamiva.media in your browser.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return ExitConfirmScope(
      child: HeroScaffold(
        heroAsset: 'assets/hero/welcome.png',
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Form(
            key: _formKey,
            child: ListView(
              children: [
                const SizedBox(height: 24),
                // Real Tamiva logo - larger, prominent
                Center(
                  child: Image.asset(
                    'assets/icon/tamiva_logo.png',
                    height: 140,
                    filterQuality: FilterQuality.high,
                  ),
                ),
                const SizedBox(height: 12),
                Center(child: Text('YOUR BRAND, ELEVATED',
                    style: textTheme.labelMedium)),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    'A creative studio\nin your pocket.',
                    textAlign: TextAlign.center,
                    style: textTheme.displayMedium,
                  ),
                ),
                const SizedBox(height: 14),
                Center(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: const [
                      CapabilityChip(
                          icon: Icons.auto_awesome,
                          label: 'Branding',
                          tint: TamivaColors.gold),
                      CapabilityChip(
                          icon: Icons.play_circle_outline,
                          label: 'Films',
                          tint: TamivaColors.ember),
                      CapabilityChip(
                          icon: Icons.language,
                          label: 'Websites',
                          tint: TamivaColors.maroon),
                      CapabilityChip(
                          icon: Icons.campaign_outlined,
                          label: 'Ads',
                          tint: TamivaColors.goldBright),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _AuthModeToggle(
                  isSignUp: _signUpMode,
                  onChanged: _setMode,
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0x0FFFF5E1),
                    border: Border.all(color: TamivaColors.divider),
                    borderRadius: BorderRadius.circular(TamivaRadii.md),
                  ),
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeInOut,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _signUpMode ? 'Start your studio' : 'Welcome back',
                          style: textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _signUpMode
                              ? "Free forever. Upgrade when you're ready."
                              : 'Sign in to keep building your brand kit.',
                          style: textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 20),
                        ..._buildFields(textTheme),
                        const SizedBox(height: 20),
                        if (_error != null) ...[
                          InlineError(
                            error: _error!,
                            onRetry: _submitting ? null : _submit,
                          ),
                          const SizedBox(height: 12),
                        ],
                        GradientCtaButton(
                          loading: _submitting,
                          onPressed: _submitting ? null : _submit,
                          child: Text(_signUpMode ? 'Start free  →' : 'Sign in  →'),
                        ),
                        if (!_signUpMode) ...[
                          const SizedBox(height: 8),
                          Center(
                            child: TextButton(
                              onPressed: _submitting
                                  ? null
                                  : () => Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => ForgotPasswordScreen(
                                              apiClient: widget.apiClient),
                                        ),
                                      ),
                              child: const Text('Forgot password?'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: TextButton(
                    onPressed: _submitting
                        ? null
                        // Both auth modes are on this same screen now,
                        // so the secondary link just toggles mode in
                        // place instead of pushing a route. The
                        // standalone LoginScreen route is still
                        // available for deep links (logout_action).
                        : () => _setMode(!_signUpMode),
                    child: Text(
                      _signUpMode
                          ? 'Have an account?  Sign in'
                          : 'New to Tamiva?  Create an account',
                      style: textTheme.labelLarge?.copyWith(
                        color: TamivaColors.gold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    'By continuing you agree to our Terms & Privacy.',
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium?.copyWith(color: TamivaColors.textFaint),
                  ),
                ),
                const SizedBox(height: 24),
                Center(
                  child: _InstagramBadge(onTap: _launchInstagram),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildFields(TextTheme textTheme) {
    if (!_signUpMode) {
      // Sign-in: email + password only.
      return [
        TextFormField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          style: textTheme.bodyLarge,
          decoration: const InputDecoration(labelText: 'EMAIL'),
          validator: (v) => (v == null || !v.contains('@'))
              ? 'Enter a valid email'
              : null,
        ),
        const SizedBox(height: 12),
        PasswordField(
          controller: _passwordController,
          label: 'PASSWORD',
          validator: (v) => (v == null || v.isEmpty)
              ? 'Enter your password'
              : null,
        ),
      ];
    }
    // Sign-up: full form.
    return [
      TextFormField(
        controller: _nameController,
        style: textTheme.bodyLarge,
        decoration: const InputDecoration(labelText: 'FULL NAME'),
        validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _phoneController,
        keyboardType: TextInputType.phone,
        style: textTheme.bodyLarge,
        decoration: const InputDecoration(
          labelText: 'MOBILE',
          hintText: '10-digit number',
        ),
        validator: (v) => (v == null || v.trim().length < 8)
            ? "That doesn't look right"
            : null,
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _emailController,
        keyboardType: TextInputType.emailAddress,
        style: textTheme.bodyLarge,
        decoration: const InputDecoration(labelText: 'EMAIL'),
        validator: (v) => (v == null || !v.contains('@'))
            ? 'Enter a valid email'
            : null,
      ),
      const SizedBox(height: 12),
      PasswordField(
        controller: _passwordController,
        label: 'PASSWORD',
        helperText: '8+ characters',
        validator: (v) => (v == null || v.length < 8)
            ? 'At least 8 characters'
            : null,
      ),
    ];
  }
}

/// Pill-style switcher: [Sign in]  [Sign up] at the top of the auth
/// card. Animated indicator slides between the two options.
class _AuthModeToggle extends StatelessWidget {
  final bool isSignUp;
  final ValueChanged<bool> onChanged;

  const _AuthModeToggle({
    required this.isSignUp,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        height: 44,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: TamivaColors.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: TamivaColors.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _AuthModePill(
              label: 'Sign in',
              selected: !isSignUp,
              onTap: () => onChanged(false),
            ),
            _AuthModePill(
              label: 'Sign up',
              selected: isSignUp,
              onTap: () => onChanged(true),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuthModePill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _AuthModePill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? TamivaColors.gold : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: selected
                      ? const Color(0xFF1A0F02)
                      : TamivaColors.textSecondary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                ),
          ),
        ),
      ),
    );
  }
}

/// Hand-styled Instagram badge - the original Tamiva chrome uses a
/// custom gradient glyph instead of depending on font_awesome_flutter
/// which had SDK conflicts at the time.
class _InstagramBadge extends StatelessWidget {
  final VoidCallback onTap;
  const _InstagramBadge({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: TamivaColors.divider),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Mini IG gradient glyph drawn as a stack so we don't pull
            // in an icon package.
            SizedBox(
              width: 16,
              height: 16,
              child: CustomPaint(painter: _IgGlyphPainter()),
            ),
            const SizedBox(width: 8),
            Text(
              '@tamiva.media',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: TamivaColors.textSecondary,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IgGlyphPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(1),
      const Radius.circular(4),
    );
    final shader = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color(0xFFFDD17B),
        Color(0xFFD62976),
        Color(0xFF4F5BD5),
      ],
    ).createShader(rect);
    final paint = Paint()..shader = shader;
    canvas.drawRRect(rrect, paint);
    final innerPaint = Paint()
      ..color = const Color(0xFF0F0507)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawRRect(
      rrect.deflate(2),
      innerPaint,
    );
    canvas.drawCircle(rect.center, size.width * 0.22, innerPaint);
    final dot = Paint()..color = const Color(0xFF0F0507);
    canvas.drawCircle(
      Offset(rect.right - 3, rect.top + 3),
      1,
      dot,
    );
  }

  @override
  bool shouldRepaint(_IgGlyphPainter oldDelegate) => false;
}
