import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Drop-in replacement for [CachedNetworkImage] that ALSO renders
/// `data:` URLs (base64-encoded bytes, e.g. gpt-image-1's `b64_json`
/// output). [CachedNetworkImage] only understands http(s), so a data
/// URL used to fail silently — showing a blank tile or an endless
/// spinner. This routes data URLs through [Image.memory] and leaves
/// http(s) URLs on the cached network path.
///
/// The constructor intentionally mirrors [CachedNetworkImage]
/// (`imageUrl`, `fit`, `placeholder`, `errorWidget`) so existing call
/// sites are a 1:1 swap.
class NetImage extends StatelessWidget {
  final String imageUrl;
  final BoxFit? fit;
  final Widget Function(BuildContext, String)? placeholder;
  final Widget Function(BuildContext, String, Object)? errorWidget;

  const NetImage({
    super.key,
    required this.imageUrl,
    this.fit,
    this.placeholder,
    this.errorWidget,
  });

  bool get _isDataUrl => imageUrl.startsWith('data:');

  /// Decodes the base64 payload of a `data:` URL. Returns null if the
  /// URL is malformed or not base64-encoded.
  Uint8List? _decodeDataUrl() {
    try {
      final comma = imageUrl.indexOf(',');
      if (comma == -1) return null;
      final meta = imageUrl.substring(5, comma); // between "data:" and ","
      final payload = imageUrl.substring(comma + 1);
      if (!meta.contains('base64')) return null; // percent-encoded, unsupported
      return base64Decode(payload);
    } catch (_) {
      return null;
    }
  }

  Widget _error(BuildContext context, Object err) {
    return errorWidget?.call(context, imageUrl, err) ??
        const Icon(Icons.broken_image);
  }

  @override
  Widget build(BuildContext context) {
    if (_isDataUrl) {
      final bytes = _decodeDataUrl();
      if (bytes == null) return _error(context, 'unreadable data url');
      return Image.memory(
        bytes,
        fit: fit,
        gaplessPlayback: true,
        errorBuilder: (ctx, err, _) => _error(ctx, err),
      );
    }

    return CachedNetworkImage(
      imageUrl: imageUrl,
      fit: fit,
      placeholder: placeholder,
      errorWidget: errorWidget,
    );
  }
}
