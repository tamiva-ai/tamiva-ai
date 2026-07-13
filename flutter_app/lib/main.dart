import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/models.dart';
import 'screens/brand_assets_screen.dart';
import 'screens/welcome_screen.dart';
import 'services/api_client.dart';
import 'services/auth_state.dart';
import 'services/connectivity_service.dart';
import 'services/draft_store.dart';
import 'theme/tamiva_theme.dart';
import 'widgets/offline_banner.dart';

void main() {
  runApp(const TamivaApp());
}

class TamivaApp extends StatelessWidget {
  const TamivaApp({super.key});

  @override
  Widget build(BuildContext context) {
    final apiClient = ApiClient(baseUrl: 'https://api.tamiva.in');
    final connectivity = ConnectivityService();

    return MaterialApp(
      title: 'Tamiva',
      theme: TamivaTheme.dark,
      darkTheme: TamivaTheme.dark,
      themeMode: ThemeMode.dark,
      home: _Bootstrap(
        apiClient: apiClient,
        connectivity: connectivity,
      ),
      navigatorKey: globalNavigatorKey,
    );
  }
}

/// v36 / S2.8 — cold start. Loads persisted session, validates via
/// /auth/me, and routes either to the brand kit (returning user) or
/// the welcome screen (signed out). Wrapped in OfflineBanner so a
/// network dead-zone at launch never shows a confusing empty screen.
class _Bootstrap extends StatefulWidget {
  final ApiClient apiClient;
  final ConnectivityService connectivity;

  const _Bootstrap({
    required this.apiClient,
    required this.connectivity,
  });

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  @override
  Widget build(BuildContext context) {
    return OfflineBanner(
      connectivity: widget.connectivity,
      child: _BootstrapInner(
        apiClient: widget.apiClient,
      ),
    );
  }
}

class _BootstrapInner extends StatefulWidget {
  final ApiClient apiClient;

  const _BootstrapInner({required this.apiClient});

  @override
  State<_BootstrapInner> createState() => _BootstrapInnerState();
}

class _BootstrapInnerState extends State<_BootstrapInner> {
  Widget? _screen;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final auth = AuthState(prefs);
    final draft = DraftStore(prefs);

    final persistedUser = auth.loadUser();
    if (persistedUser == null) {
      if (!mounted) return;
      setState(() {
        _screen = WelcomeScreen(apiClient: widget.apiClient);
        _resolved = true;
      });
      return;
    }

    widget.apiClient.setUserId(persistedUser.id);

    final me = await widget.apiClient.fetchMe();
    final tierSnapshot = await widget.apiClient.refreshTier();
    User? effectiveUser = me;
    if (effectiveUser != null && tierSnapshot != null) {
      effectiveUser = User(
        id: effectiveUser.id,
        email: effectiveUser.email,
        fullName: effectiveUser.fullName,
        phone: effectiveUser.phone,
        tier: tierSnapshot.tier,
        tierUpdatedAt: tierSnapshot.tierUpdatedAt,
        tierExpiresAt: tierSnapshot.tierExpiresAt,
      );
    }
    effectiveUser ??= persistedUser;

    Widget next;
    if (effectiveUser == null) {
      await auth.clear();
      widget.apiClient.setUserId(null);
      next = WelcomeScreen(apiClient: widget.apiClient);
    } else {
      await auth.saveUser(effectiveUser);

      BusinessProfile? profile;
      try {
        profile = await widget.apiClient.getBusinessProfileByUser(
          effectiveUser.id,
        );
      } catch (_) {
        profile = null;
      }

      if (profile != null) {
        next = BrandAssetsScreen(
          apiClient: widget.apiClient,
          businessProfileId: profile.id,
        );
      } else {
        next = WelcomeScreen(apiClient: widget.apiClient);
      }
    }

    draft.loadBusinessInfo();

    if (!mounted) return;
    setState(() {
      _screen = next;
      _resolved = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_screen != null) {
      return _screen!;
    }
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0D),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/icon/tamiva_logo.png',
              height: 100,
              filterQuality: FilterQuality.high,
            ),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            const Text('Starting your studio…'),
          ],
        ),
      ),
    );
  }
}

final globalNavigatorKey = GlobalKey<NavigatorState>();

BuildContext? rootContext() => globalNavigatorKey.currentContext;
