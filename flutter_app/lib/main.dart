import 'package:flutter/material.dart';
import 'services/api_client.dart';
import 'screens/welcome_screen.dart';
import 'theme/tamiva_theme.dart';

void main() {
  runApp(const TamivaApp());
}

class TamivaApp extends StatelessWidget {
  const TamivaApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Points at the live backend deployed on Railway.
    // Custom domain. The Railway auto-generated hostname
    // (tamiva-ai-production.up.railway.app) gets DNS_PROBE_FINISHED
    // _NXDOMAIN on some mobile carriers, so we use the canonical
    // api.tamiva.in instead. CNAME points to Railway; Railway handles
    // TLS via the custom-domain setting.
    final apiClient = ApiClient(baseUrl: 'https://api.tamiva.in');

    return MaterialApp(
      title: 'Tamiva',
      theme: TamivaTheme.dark,
      darkTheme: TamivaTheme.dark,
      themeMode: ThemeMode.dark,
      home: WelcomeScreen(apiClient: apiClient),
    );
  }
}
