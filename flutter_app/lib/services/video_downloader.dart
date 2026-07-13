import 'dart:io';
import 'dart:typed_data';

import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';

/// v36 / S2.11 — in-app video player + gallery download for films.
///
/// Uses `video_player` so the user can preview the film inside Tamiva
/// instead of being bounced to a browser, and `gal` (with a manual
/// permission_handler fallback) to save the underlying file to the
/// device gallery.
///
/// Returns the bytes on success so callers (e.g. share) can use them
/// without re-downloading.
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

  /// Downloads the film to disk and tries to put it in the device
  /// gallery via gal. On Android 13+ (where legacy
  /// WRITE_EXTERNAL_STORAGE is gone), `gal` is granted via Photo
  /// Access permission instead. On older versions the manifest's
  /// WRITE_EXTERNAL_STORAGE suffices.
  static Future<FilmPlaybackResult> downloadToGallery(String url) async {
    http.Response res;
    try {
      res = await http.get(Uri.parse(url));
    } catch (_) {
      return const FilmPlaybackResult.failure(
        "Couldn't download the film. Check your connection.",
      );
    }
    if (res.statusCode != 200) {
      return const FilmPlaybackResult.failure(
        "Couldn't download the film. Try again in a moment.",
      );
    }
    final bytes = res.bodyBytes;

    final hasAccess = await _ensurePhotoAccess();
    if (!hasAccess) {
      return const FilmPlaybackResult.failure(
        'Photo access is off. Enable it in Settings to save films.',
      );
    }

    try {
      await Gal.putVideoBytes(bytes, album: 'Tamiva');
      return FilmPlaybackResult.success(bytes);
    } on GalException catch (e) {
      if (e.type == GalExceptionType.accessDenied) {
        return const FilmPlaybackResult.failure(
          'Photo access is off. Enable it in Settings to save films.',
        );
      }
      return const FilmPlaybackResult.failure(
        "Couldn't save the film. Try again.",
      );
    } catch (_) {
      return const FilmPlaybackResult.failure(
        "Couldn't save the film. Try again.",
      );
    }
  }

  static Future<bool> _ensurePhotoAccess() async {
    // iOS + older Android: gal.putVideoBytes handles internally.
    if (!(Platform.isAndroid || Platform.isIOS)) return true;
    // Android 13+: must request Photos permission explicitly.
    if (Platform.isAndroid) {
      final status = await Permission.photos.status;
      if (status.isGranted) return true;
      final result = await Permission.photos.request();
      return result.isGranted;
    }
    // iOS: photo library add-only is requested inside gal.
    return true;
  }

  /// v36 / S3.21 — deep-link helper. Returns the user to a system
  /// Settings screen for app-level permission management when the user
  /// has previously denied gallery access.
  static Future<void> openAppSettings() async {
    await Permission.photos.request();
    await openAppSettings();
  }
}