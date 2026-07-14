import 'package:flutter/material.dart';
import '../errors/user_facing_error.dart';
import '../services/api_client.dart';
import '../theme/tamiva_theme.dart';
import '../widgets/hero_scaffold.dart';
import '../widgets/inline_error.dart';
import '../widgets/password_field.dart';
import 'business_info_screen.dart';
import 'forgot_password_screen.dart';

class LoginScreen extends StatefulWidget {
  final ApiClient apiClient;

  const LoginScreen({super.key, required this.apiClient});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  UserFacingError? _error;

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final user = await widget.apiClient.login(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => BusinessInfoScreen(
            apiClient: widget.apiClient,
            userId: user.id,
            tier: user.tier,
            skipLockPrefetch: user.isPaid,
          ),
        ),
      );
    } on ApiException catch (e) {
      // 401 needs specific wording - "incorrect email or password" - since
      // the generic UserFacingError treats it as a session issue.
      if (e.statusCode == 401) {
        setState(() => _error = const UserFacingError(
              title: 'Check your details',
              message: "That email and password don't match. Try again or reset your password.",
              retryLabel: null,
            ));
      } else {
        setState(() => _error = UserFacingError.from(e, operation: 'sign in'));
      }
    } catch (e) {
      setState(() => _error = UserFacingError.from(e, operation: 'sign in'));
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
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              const SizedBox(height: 16),
              Center(
                child: Image.asset(
                  'assets/icon/tamiva_logo.png',
                  height: 100,
                  filterQuality: FilterQuality.high,
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text('WELCOME BACK', style: textTheme.labelMedium),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  'Sign in.',
                  textAlign: TextAlign.center,
                  style: textTheme.displayMedium,
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
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
                      validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 20),
                    if (_error != null) ...[
                      InlineError(
                        error: _error!,
                        onRetry: _submitting ? null : _login,
                      ),
                      const SizedBox(height: 12),
                    ],
                    GradientCtaButton(
                      loading: _submitting,
                      onPressed: _submitting ? null : _login,
                      child: const Text('Sign in  →'),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: TextButton(
                        onPressed: _submitting
                            ? null
                            : () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => ForgotPasswordScreen(
                                      apiClient: widget.apiClient,
                                    ),
                                  ),
                                ),
                        child: const Text('Forgot password?'),
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
