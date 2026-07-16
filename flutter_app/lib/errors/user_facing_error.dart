import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../services/api_client.dart';

/// A friendly, human-readable representation of a failure. Every layer
/// of the app should show these instead of raw exceptions.
class UserFacingError {
  /// 2-4 word summary suitable for a dialog title or error card header.
  final String title;

  /// One-sentence explanation the user can act on. Never mentions
  /// internal component names ("worker", "queue", "prisma") or codes.
  final String message;

  /// Optional label for a retry button. Null means retry doesn't make
  /// sense here (e.g. a 409 - retrying wouldn't help).
  final String? retryLabel;

  /// Optional richer hint for the user - e.g. suggesting they check
  /// their internet, or try a different email.
  final String? hint;

  const UserFacingError({
    required this.title,
    required this.message,
    this.retryLabel = 'Try again',
    this.hint,
  });

  /// Translate any thrown thing into a UserFacingError. Callers pass in
  /// the current [operation] so the wording can be specific ("Couldn't
  /// send the code" vs generic "Something went wrong").
  static UserFacingError from(Object error, {String operation = 'do that'}) {
    // API layer - we have a status code to reason about.
    if (error is ApiException) {
      return _fromApi(error, operation);
    }

    // Network layer - no route to backend at all.
    if (error is SocketException || error is HttpException) {
      return UserFacingError(
        title: "You're offline",
        message: "Your internet dropped, or the studio is briefly unreachable. Check your connection and try again.",
        hint: 'If it keeps happening, try switching between wifi and mobile data.',
      );
    }

    // Timeouts - request went out but didn't come back.
    if (error is TimeoutException) {
      return const UserFacingError(
        title: 'Taking too long',
        message: "The studio didn't respond in time. This usually clears up on retry.",
      );
    }

    // Parsing errors from bad backend responses.
    if (error is FormatException) {
      return const UserFacingError(
        title: 'Studio hiccup',
        message: 'We received a response we didn\'t expect. If this keeps happening, let us know.',
      );
    }

    // Fall-through: keep the raw message OUT of the user's face, but log
    // it so future us can see the pattern. Surface the exception type in
    // the message so the user can report something more useful than
    // "Something unexpected" if it keeps happening.
    final typeName = _friendlyTypeName(error);
    return UserFacingError(
      title: "Couldn't ${_pastToInfinitive(operation)}",
      message: typeName == null
          ? 'Something unexpected happened. Try again in a moment.'
          : 'Something unexpected happened ($typeName). Try again in a moment.',
    );
  }

  /// Map common runtime exception types to user-readable names so the
  /// fall-through message gives support a useful hint. Returns null for
  /// types we deliberately don't surface (anything internal).
  static String? _friendlyTypeName(Object error) {
    final t = error.runtimeType.toString();
    switch (t) {
      case 'TypeError':
        return 'response shape mismatch';
      case 'RangeError':
        return 'value out of range';
      case 'StateError':
        return 'unexpected state';
      case 'NoSuchMethodError':
        return 'missing handler';
      case 'JsonUnsupportedObjectError':
        return 'unserializable value';
      case 'HandshakeException':
        return 'TLS handshake failed';
      default:
        return null;
    }
  }

  static UserFacingError _fromApi(ApiException e, String operation) {
    final backendMessage = _extractBackendMessage(e.body);

    switch (e.statusCode) {
      case 400:
        return UserFacingError(
          title: 'Check your details',
          message: backendMessage ?? "Something in what you entered doesn't look right.",
          retryLabel: null,
        );
      case 401:
      case 403:
        // 401 during sign in is wrong credentials, not session expiry.
        // The auth routes return 401 for both, so we disambiguate by
        // looking at the [operation] the caller passed to .from().
        // (See api_client.dart - login returns userId on success.)
        if (operation.toLowerCase().contains('sign')) {
          return const UserFacingError(
            title: 'Check your details',
            message: "That email and password don't match. Try again or reset your password.",
            retryLabel: null,
          );
        }
        return const UserFacingError(
          title: 'Sign in again',
          message: "Your session isn't valid anymore. Please sign in and try again.",
          retryLabel: null,
        );
      case 404:
        return UserFacingError(
          title: 'Not found',
          message: backendMessage ?? "We couldn't find what you were looking for.",
          retryLabel: null,
        );
      case 409:
        // Caller should handle 409 specifically (e.g. "email exists"
        // dialog); this is just a fallback if they don't.
        return UserFacingError(
          title: 'Conflict',
          message: backendMessage ?? 'That already exists.',
          retryLabel: null,
        );
      case 429:
        // Distinguish a transient rate-limit (slow down) from a hard
        // quota cap (the backend tells us via `upgradeCopy: true` in
        // the JSON body). v36 / S2.9 — copy now matches the actual
        // model ("1 total", not "refreshes at midnight") and surfaces
        // an upgrade CTA at the highest-intent moment.
        final body = backendMessage ?? '';
        final isQuotaCap = body.toLowerCase().contains("used your 1 free");
        return UserFacingError(
          title: isQuotaCap ? 'Free generation used' : 'Slow down',
          message: isQuotaCap
              ? "You've used your 1 free generation for this. Upgrade to Tamiva Pro for unlimited."
              : "You're going a bit fast. Give it a moment and try again.",
          retryLabel: isQuotaCap ? 'Upgrade to Pro' : 'Try again',
        );
      case 500:
      case 502:
      case 503:
        return const UserFacingError(
          title: 'Studio hiccup',
          message: "The studio is catching up. This usually clears in a few seconds.",
        );
      default:
        return UserFacingError(
          title: "Couldn't ${_pastToInfinitive(operation)}",
          message: backendMessage ?? 'Something unexpected happened. Try again in a moment.',
        );
    }
  }

  /// Extract a friendly error string from the backend's JSON body.
  /// Backends returning `{"error": "..."}` are common; if the body is
  /// something weirder we bail out and let the caller pick a generic
  /// message.
  static String? _extractBackendMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is String) {
        final msg = decoded['error'] as String;
        // Guard against backend leaking stack traces or internals.
        if (msg.length < 200 && !msg.contains('at ')) return msg;
      }
    } catch (_) {}
    return null;
  }

  static String _pastToInfinitive(String operation) {
    // "sign in" stays "sign in"; the caller already passes the base
    // verb phrase. Trim any trailing punctuation just in case.
    return operation.replaceAll(RegExp(r'[.!?]+$'), '');
  }
}
