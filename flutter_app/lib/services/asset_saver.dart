import 'dart:convert';
import 'dart:typed_data';

import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

/// Result of a save attempt. [error] is null on success and carries a
/// short, user-facing message on failure.
class SaveResult {
  final bool ok;
  final String? error;
  const SaveResult.success() : ok = true, error = null;
  const SaveResult.failure(this.error) : ok = false;
}

/// Saves a generated image asset to the device photo gallery.
///
/// Handles both `data:` URLs (base64 bytes returned by gpt-image-1) and
/// http(s) URLs (which are downloaded first). Videos are not handled
/// here — open those in the browser via url_launcher instead.
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
    return const