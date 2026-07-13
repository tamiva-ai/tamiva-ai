import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';

/// v36 / S3.17 — share sheet helpers for generated assets. Used by:
///   - "Save all" / "Share all" on a finished carousel
///   - "Share" on an individual carousel slide or logo
///   - "Share film" once the video bytes are downloaded
///
/// Uses `share_plus`'s `XFile.fromData` so we never touch the file
/// system directly — the platform plugins handle temp caching.
class ShareService {
  /// Shares an image given a URL (http, https, or data:).
  /// Pass [name] so the recipient app gets a sensible filename.
  static Future<void> shareImageUrl(
    String url, {
    String? name,
    String? text,
  }) async {
    try {
      final bytes = await _downloadAsBytes(url);
      final fileName = name ?? _guessFileName(url, 'png');
      await Share.shareXFiles(
        [XFile.fromData(bytes, name: fileName, mimeType: 'image/png')],
        text: text,
      );
    } catch (_) {
      // Swallow — caller surfaces a SnackBar. Sharing is best-effort.
    }
  }

  /// Shares a film given its raw bytes (e.g. just-downloaded by the
  /// film downloader).
  static Future<void> shareVideoBytes(
    Uint8List bytes, {
    String name = 'Tamiva Film.mp4',
    String? text,
  }) async {
    try {
      await Share.shareXFiles(
        [XFile.fromData(bytes, name: name, mimeType: 'video/mp4')],
        text: text,
      );
    } catch (_) {
      // best-effort
    }
  }

  static Future<Uint8List> _downloadAsBytes(String url) async {
    if (url.startsWith('data:')) {
      final comma = url.indexOf(',');
      if (comma == -1) {
        throw const FormatException('Invalid data URL');
      }
      final meta = url.substring(5, comma);
      if (!meta.contains('base64')) {
        throw const FormatException('Only base64 data URLs supported');
      }
      return base64Decode(url.substring(comma + 1));
    }
    final res = await http.get(Uri.parse(url));
    if (res.statusCode != 200) {
      throw HttpException('Image download failed: ${res.statusCode}');
    }
    return res.bodyBytes;
  }

  static String _guessFileName(String url, String fallbackExtension) {
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments;
      if (segments.isNotEmpty) {
        final last = segments.last;
        if (last.contains('.')) return last;
      }
    } catch (_) {}
    return 'tamiva-$fallbackExtension';
  }
}