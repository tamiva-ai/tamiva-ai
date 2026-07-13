import 'dart:convert';
import 'dart:typed_data';

import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart' show PlatformException;

/// Result of a save attempt.
class SaveResult {
  final bool ok;
  final String? error;
  const SaveResult.success() : ok = true, error = null;
  const SaveResult.failure(this.error) : ok = false;
}

/// Saves a generated image asset to the device photo gallery.
Future<SaveResult> saveImageToGallery(
  String url, {
  String album = 'Tamiva',
}) async {
  Uint8List bytes;
  try {
    if (url.startsWith('data:')) {
      final comma = url.indexOf(',');
      if (comma == -1) return const SaveResult.failure("That image couldn't be read.");
      final meta = url.substring(5, comma);
      if (!meta.contains('base64')) {
        return const SaveResult.failure("That image format isn't supported.");
      }
      bytes = base64Decode(url.substring(comma + 1));
    } else {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode != 200) {
        return const SaveResult.failure("Couldn't download the image.");
      }
      bytes = res.bodyBytes;
    }
  } catch (_) {
    return const SaveResult.failure("Couldn't read the image.");
  }

  try {
    await Gal.putImageBytes(bytes, album: album);
    return const SaveResult.success();
  } on GalException catch (e) {
    if (e.type == GalExceptionType.accessDenied) {
      return const SaveResult.failure(
        'Storage permission is off. Enable it in Settings to save.',
      );
    }
    return const SaveResult.failure("Couldn't save to your gallery.");
  } catch (_) {
    return const SaveResult.failure("Couldn't save to your gallery.");
  }
}

/// v36 / S3.21 — settings deep-link helper. We don't use the
/// `permission_handler` package (which has Android BuildConfig issues
/// in many Flutter SDK combos) — instead we route the user back to
/// the welcome screen and surface the existing system hint via the
/// friendly SnackBar copy already shown by [saveImageToGallery].
Future<void> openAppSettingsForSaves() async {
  // No-op: the underlying Gal plugin will trigger Android's Settings
  // page itself on the next attempt if the user granted "Don't ask
  // again" on Android 13+. For richer deep-linking we'd add
  // permission_handler ^11.3.x — out of scope for this milestone.
}
