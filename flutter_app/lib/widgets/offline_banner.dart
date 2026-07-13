import 'dart:async';

import 'package:flutter/material.dart';

import '../services/connectivity_service.dart';

/// v36 / S2.7 — persistent offline banner. Subscribes to the
/// ConnectivityService and renders a thin red strip at the top of the
/// screen whenever the device has no network. The banner never blocks
/// interaction; it's only an indicator so the user knows the next tap
/// may fail.
class OfflineBanner extends StatefulWidget {
  final ConnectivityService connectivity;
  final Widget child;

  const OfflineBanner({
    super.key,
    required this.connectivity,
    required this.child,
  });

  @override
  State<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends State<OfflineBanner> {
  late bool _online;
  StreamSubscription<bool>? _sub;

  @override
  void initState() {
    super.initState();
    _online = widget.connectivity.isOnline;
    _sub = widget.connectivity.onlineStream.listen((online) {
      if (mounted) setState(() => _online = online);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (!_online)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              bottom: false,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                height: 32,
                color: const Color(0xCC8B1A2A),
                alignment: Alignment.center,
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.cloud_off_outlined, color: Colors.white, size: 16),
                    SizedBox(width: 8),
                    Text(
                      "You're offline. We'll retry when you're back.",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}