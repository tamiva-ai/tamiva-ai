import 'package:flutter/material.dart';
import '../errors/user_facing_error.dart';
import '../services/api_client.dart';
import '../theme/tamiva_theme.dart';
import '../widgets/hero_scaffold.dart';
import '../widgets/inline_error.dart';
import '../widgets/password_field.dart';
import 'business_info_screen.dart';

/// Three-step password reset:
///   1. User enters email → backend emails a 6-digit code
///   2. User enters the code
///   3. User sets a new password → auto sign in
///
/// The backend keeps codes in memory for 15 min; expiry / typos surface
/// as inline errors, not silent failures.
class ForgotPasswordScreen extends StatefulWidget {
  final ApiClient apiClient;

  /// Optional email to prefill in step 1 — used by the "Email already
  /// registered" dialog on the welcome screen, so the user lands on the
  /// code-request step without re-typing.
  final String? prefillEmail;

  const ForgotPasswordScreen({
    super.key,
    required this.apiClient,
    this.prefillEmail,
  });

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

enum _Step { enterEmail, enterCode, setPassword }

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  _Step _step = _Step.enterEmail;

  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmController = TextEditingController();

  final _emailKey = GlobalKey<FormState>();
  final _codeKey = GlobalKey<FormState>();
  final _passwordKey = GlobalKey<FormState>();

  bool _submitting = false;
  UserFacingError? _error;
  // Backend allows 5 attempts before invalidating the code; mirror that
  // count locally so we can show "N tries left" without a round-trip.
  static const int _maxCodeAttempts = 5;
  int _codeAttempts = 0;

  @override
  void initState() {
    super.initState();
    // v37: welcome screen hands off the email so the user lands on the
    // code-request step without re-typing.
    if (widget.prefillEmail != null && widget.prefillEmail!.isNotEmpty) {
      _emailController.text = widget.prefillEmail!;
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _newPasswordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  String get _email => _emailController.text.trim().toLowerCase();

  Future<void> _sendCode() async {
    if (!_emailKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.apiClient.forgotPassword(email: _email);
      if (!mounted) return;
      setState(() {
        _step = _Step.enterCode;
        _codeAttempts = 0; // reset counter when a new code arrives
      });
    } catch (e) {
      setState(() => _error = UserFacingError.from(e, operation: 'send the code'));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _resendCode() async {
    try {
      await widget.apiClient.forgotPassword(email: _email);
      if (!mounted) return;
      setState(() => _codeAttempts = 0);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A new code is on its way.')),
      );
    } catch (_) {
      // Silent - user can just tap again if nothing arrives.
    }
  }

  void _advanceToPasswordStep() {
    if (!_codeKey.currentState!.validate()) return;
    setState(() {
      _error = null;
      _step = _Step.setPassword;
    });
  }

  Future<void> _finishReset() async {
    if (!_passwordKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final user = await widget.apiClient.resetPassword(
        email: _email,
        code: _codeController.text.trim(),
        newPassword: _newPasswordController.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password updated. Signed you in.')),
      );
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => BusinessInfoScreen(
            apiClient: widget.apiClient,
            userId: user.id,
            tier: user.tier,
            skipLockPrefetch: user.isPaid,
          ),
        ),
        (route) => false,
      );
    } on ApiException catch (e) {
      // 400 from a bad/expired code sends the user back to the code
      // step with attempt tracking so they know how many chances remain.
      if (e.statusCode == 400 && mounted) {
        _codeAttempts++;
        final remaining = _maxCodeAttempts - _codeAttempts;
        setState(() {
          _step = _Step.enterCode;
          if (remaining <= 0) {
            _error = const UserFacingError(
              title: 'Code invalidated',
              message: 'Too many wrong attempts. Request a new code and try again.',
              retryLabel: null,
            );
          } else {
            _error = UserFacingError(
              title: 'Wrong code',
              message: "That code didn't match. $remaining ${remaining == 1 ? 'try' : 'tries'} left.",
              retryLabel: null,
            );
          }
        });
      } else if (mounted) {
        setState(() => _error = UserFacingError.from(e, operation: 'reset your password'));
      }
    } catch (e) {
      if (mounted) setState(() => _error = UserFacingError.from(e, operation: 'reset your password'));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return HeroScaffold(
      heroAsset: 'assets/hero/welcome.png',
      showBackButton: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: ListView(
          children: [
            const SizedBox(height: 24),
            Center(
              child: Image.asset(
                'assets/icon/tamiva_logo.png',
                height: 90,
                filterQuality: FilterQuality.high,
              ),
            ),
            const SizedBox(height: 16),
            Center(child: Text('RESET PASSWORD', style: textTheme.labelMedium)),
            const SizedBox(height: 12),
            Center(
              child: Text(
                _stepHeadline,
                textAlign: TextAlign.center,
                style: textTheme.displayMedium,
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                _stepSubtitle,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 32),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0x0FFFF5E1),
                border: Border.all(color: TamivaColors.divider),
                borderRadius: BorderRadius.circular(TamivaRadii.md),
              ),
              child: _buildStepBody(context),
            ),
          ],
        ),
      ),
    );
  }

  String get _stepHeadline {
    switch (_step) {
      case _Step.enterEmail:
        return 'What email?';
      case _Step.enterCode:
        return 'Check your inbox.';
      case _Step.setPassword:
        return 'New password.';
    }
  }

  String get _stepSubtitle {
    switch (_step) {
      case _Step.enterEmail:
        return "We'll email you a 6-digit code.";
      case _Step.enterCode:
        return 'We sent a code to $_email. It expires in 15 minutes.';
      case _Step.setPassword:
        return 'Almost done. Set a strong password.';
    }
  }

  Widget _buildStepBody(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    switch (_step) {
      case _Step.enterEmail:
        return Form(
          key: _emailKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                autofocus: true,
                style: textTheme.bodyLarge,
                decoration: const InputDecoration(labelText: 'EMAIL'),
                validator: (v) =>
                    (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
              ),
              const SizedBox(height: 20),
              if (_error != null) ...[
                InlineError(error: _error!),
                const SizedBox(height: 12),
              ],
              GradientCtaButton(
                loading: _submitting,
                onPressed: _submitting ? null : _sendCode,
                child: const Text('Send code  →'),
              ),
            ],
          ),
        );

      case _Step.enterCode:
        return Form(
          key: _codeKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                autofocus: true,
                style: textTheme.displayMedium?.copyWith(letterSpacing: 12),
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  labelText: '6-DIGIT CODE',
                  counterText: '',
                ),
                validator: (v) => (v == null || v.trim().length != 6)
                    ? 'Enter the 6-digit code'
                    : null,
              ),
              const SizedBox(height: 12),
              if (_error != null) ...[
                InlineError(error: _error!),
                const SizedBox(height: 12),
              ],
              GradientCtaButton(
                onPressed: _advanceToPasswordStep,
                child: const Text('Verify code  →'),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: _resendCode,
                  child: const Text('Resend code'),
                ),
              ),
            ],
          ),
        );

      case _Step.setPassword:
        return Form(
          key: _passwordKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PasswordField(
                controller: _newPasswordController,
                label: 'NEW PASSWORD',
                helperText: '8+ characters',
                autofocus: true,
                validator: (v) =>
                    (v == null || v.length < 8) ? 'At least 8 characters' : null,
              ),
              const SizedBox(height: 12),
              PasswordField(
                controller: _confirmController,
                label: 'CONFIRM NEW PASSWORD',
                validator: (v) => (v != _newPasswordController.text)
                    ? "Passwords don't match"
                    : null,
              ),
              const SizedBox(height: 20),
              if (_error != null) ...[
                InlineError(error: _error!),
                const SizedBox(height: 12),
              ],
              GradientCtaButton(
                loading: _submitting,
                onPressed: _submitting ? null : _finishReset,
                child: const Text('Reset password  →'),
              ),
            ],
          ),
        );
    }
  }
}
