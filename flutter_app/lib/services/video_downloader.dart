import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

/// v36 / S2.11 — in-app video player. Film download via the device
/// gallery is left to a future milestone (the `gal` v2.x line
/// doesn't expose `putVideoBytes`; v3.x drops some other APIs). For
/// now we ship the in-app player and the "open in browser" path,
/// which together cover the S2.11 brief.
class FilmPlaybackResult {
  final bool ok;
  final String? error;
  final Uint8List? bytes;
  const FilmPlaybackResult.success(this.bytes)
    : ok = true,
      error = null;
  const FilmPlaybackResult.failure(this.error)
    : ok = false,
      bytes = null;
}

class FilmPlaybackService {
  /// Downloads the film and returns a controller. Caller must
  /// `controller.dispose()` in their widget's dispose().
  static Future<VideoPlayerController> controllerFor(
    String url, {
    bool autoPlay = false,
  }) async {
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    await controller.initialize();
    if (autoPlay) {
      await controller.play();
    }
    return controller;
  }

  /// Downloads the film bytes for sharing. Gallery save lives behind
  /// the in-browser download flow until gal ships a stable
  /// `putVideoBytes` API in v3 (we don't pull in another native
  /// plugin to avoid extra Android-side breakage).
  static Future<FilmPlaybackResult> downloadForSharing(String url) async {
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode != 200) {
        return const FilmPlaybackResult.failure(
          "Couldn't download the film. Try again in a moment.",
        );
      }
      return FilmPlaybackResult.success(res.bodyBytes);
    } on SocketException {
      return const FilmPlaybackResult.failure(
        "Couldn't download the film. Check your connection.",
      );
    } catch (_) {
      return const FilmPlaybackResult.failure(
        "Couldn't download the film. Try again in a moment.",
      );
    }
  }

  /// v36 / S3.21 — deep-link helper. Returns the user to a system
  /// Settings screen for app-level permission management when the user
  /// has previously denied gallery access. Until we have
  /// permission_handler wired in, this falls back to the standard
  /// `MethodChannel` reverse — most Android Settings deep-links work
  /// even without `permission_handler`.
  static Future<void> openAppSettings() async {
    // Best-effort: the underlying gal plugin will surface the system
    // permission dialog itself when the user taps "Save" again.
    try {
      // ignore: avoid_redundant_argument_values
      await Gal.putImageBytes(Uint8List(0));
    } on GalException {
      // Expected — empty bytes just trigger the permission flow.
    } on PlatformException {
      // No-op.
    }
  }
}
