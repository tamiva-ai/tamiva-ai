// lib/services/api_logger.dart
//
// v37.1: thin request/response logger that wraps the global HTTP client
// so every click in the app emits both a local console line and (optionally)
// a fire-and-forget POST to `POST /admin/logs` for the Tamiva admin
// dashboard. The wrapper observes the existing transport; it does not
// change retry, timeout, or auth behavior.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Configuration for [ApiLogger].
///
/// Defaults: console logging ON (visible in `flutter run`), remote
/// POST OFF (so production isn't accidentally emitting analytics
/// traffic). Flip `enableRemote` on once the backend admin endpoint
/// is live.
class LogConfig {
  /// Print every request/response/error to the device console. Cheap,
  /// no network impact. Useful in dev/staging and on-device debugging.
  final bool enableConsole;

  /// POST each log line to the admin endpoint. Gated because the
  /// extra round-trip costs latency and bandwidth.
  final bool enableRemote;

  /// Admin endpoint that receives the logs (e.g.
  /// `Uri.parse('https://api.tamiva.in/admin/logs')`).
  final Uri? remoteEndpoint;

  /// Optional user/business profile ids to attach to every log entry.
  /// Set these from `ApiClient.setUserId(...)` so the admin dashboard
  /// can group logs by user.
  String? userId;
  String? businessProfileId;

  /// Body size cap per entry. Larger payloads are sliced. Default 4 KB.
  final int truncateBodyAt;

  /// Network timeout for the remote POST. Short on purpose so a slow
  /// admin endpoint never adds latency to the user-facing request.
  final Duration remoteTimeout;

  LogConfig({
    this.enableConsole = true,
    this.enableRemote = false,
    this.remoteEndpoint,
    this.userId,
    this.businessProfileId,
    this.truncateBodyAt = 4096,
    this.remoteTimeout = const Duration(seconds: 5),
  });
}

/// v37.1: global singleton. Initialize once from `main.dart` with a
/// [LogConfig]; subsequent calls reset the config (handy for tests).
class ApiLogger {
  ApiLogger._();
  static final ApiLogger instance = ApiLogger._();

  LogConfig _config = LogConfig();
  LogConfig get config => _config;

  void init(LogConfig config) {
    _config = config;
  }

  /// Reset to default (console only, no remote). Tests use this between
  /// runs so log state doesn't leak.
  void reset() {
    _config = LogConfig();
  }

  String _clipBody(Object? body) {
    if (body == null) return '';
    String s;
    if (body is String) {
      s = body;
    } else {
      try {
        s = jsonEncode(body);
      } catch (_) {
        s = body.toString();
      }
    }
    if (s.length <= _config.truncateBodyAt) return s;
    return '${s.substring(0, _config.truncateBodyAt)}...[truncated ${s.length - _config.truncateBodyAt} chars]';
  }

  Future<void> logRequest({
    required String method,
    required Uri uri,
    Object? body,
  }) async {
    if (!_config.enableConsole && !_config.enableRemote) return;
    final bodyStr = _clipBody(body);
    _console(method, uri, bodyStr, null, null, isError: false, stackTrace: null);
    await _remote({
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': 'request',
      'method': method,
      'url': uri.toString(),
      'requestBody': bodyStr,
      'userId': _config.userId,
      'businessProfileId': _config.businessProfileId,
    });
  }

  Future<void> logResponse({
    required String method,
    required Uri uri,
    required int statusCode,
    required String body,
    required int elapsedMs,
  }) async {
    if (!_config.enableConsole && !_config.enableRemote) return;
    final bodyStr = _clipBody(body);
    _console(method, uri, bodyStr, statusCode, elapsedMs, isError: false, stackTrace: null);
    await _remote({
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': 'response',
      'method': method,
      'url': uri.toString(),
      'statusCode': statusCode,
      'elapsedMs': elapsedMs,
      'responseBody': bodyStr,
      'userId': _config.userId,
      'businessProfileId': _config.businessProfileId,
    });
  }

  Future<void> logError({
    required String method,
    required Uri uri,
    required Object error,
    int? elapsedMs,
    StackTrace? stackTrace,
  }) async {
    if (!_config.enableConsole && !_config.enableRemote) return;
    final errStr = error.toString();
    _console(method, uri, errStr, null, elapsedMs, isError: true, stackTrace: stackTrace);
    if (stackTrace != null && _config.enableConsole) {
      // v37.1: also log the stack trace so on-device debugging
      // surfaces the actual failing frame, not just error.toString().
      // This is what makes the "Something unexpected happened" fall-
      // through in `UserFacingError.from` diagnosable.
      developer.log(
        'Stack trace for $method $uri',
        name: 'api',
        error: error,
        stackTrace: stackTrace,
      );
    }
    await _remote({
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': 'error',
      'method': method,
      'url': uri.toString(),
      'error': errStr,
      'errorType': error.runtimeType.toString(),
      'elapsedMs': elapsedMs,
      'userId': _config.userId,
      'businessProfileId': _config.businessProfileId,
    });
  }

  void _console(
    String method,
    Uri uri,
    String body,
    int? statusCode,
    int? elapsedMs, {
    bool isError = false,
    StackTrace? stackTrace,
  }) {
    if (!_config.enableConsole) return;
    final arrow = isError ? 'X' : '>';
    final back = isError ? 'X' : '<';
    if (statusCode != null) {
      developer.log(
        '[$back] $method $uri $statusCode'
        '${elapsedMs != null ? ' in ${elapsedMs}ms' : ''}'
        '${body.isEmpty ? '' : ' body=$body'}',
        name: 'api',
      );
    } else {
      developer.log(
        '[$arrow] $method $uri'
        '${body.isEmpty ? '' : ' body=$body'}',
        name: 'api',
        error: isError ? body : null,
        stackTrace: isError ? stackTrace : null,
      );
    }
    if (kDebugMode) {
      // Mirror in the default Flutter dev log so it shows up in
      // `flutter run` output without extra plumbing.
      // ignore: avoid_print
      print('[api] $method $uri ${statusCode ?? ''}');
    }
  }

  /// Fire-and-forget remote POST. Errors are swallowed so a broken
  /// admin endpoint can't ever affect the user-facing request path.
  Future<void> _remote(Map<String, Object?> entry) async {
    if (!_config.enableRemote || _config.remoteEndpoint == null) return;
    final endpoint = _config.remoteEndpoint!;
    try {
      final client = http.Client();
      try {
        await client
            .post(
              endpoint,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode(entry),
            )
            .timeout(_config.remoteTimeout);
      } finally {
        client.close();
      }
    } catch (_) {
      // Intentionally silent — admin logging is best-effort and
      // never blocks user actions.
    }
  }
}

/// v37.1: an http.Client that delegates to another client while
/// emitting a request/response/error log entry around every send().
///
/// Used by `ApiClient` so every existing call site continues to call
/// `_http.post(...)` / `_http.get(...)` while the wrapper observes
/// each request.
class LoggingHttpClient extends http.BaseClient {
  LoggingHttpClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final method = request.method;
    final uri = request.url;
    Object? requestBody;
    if (request is http.Request) {
      // http.Request exposes the body that will be sent. Multipart
      // requests leave this null; that's fine — multipart bodies
      // are large and not interesting for the admin dashboard.
      requestBody = request.body.isEmpty ? null : request.body;
    }
    final logger = ApiLogger.instance;
    final started = DateTime.now();
    await logger.logRequest(
      method: method,
      uri: uri,
      body: requestBody,
    );
    try {
      final response = await _inner.send(request);
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      // Buffer the raw response bytes so we can both log them
      // and replay them to the original caller without any
      // re-encoding round-trip. utf8.decode (rather than
      // String.fromCharCodes) preserves the response body
      // exactly as the server sent it, even for non-UTF-8
      // payloads (binary upload responses, etc.).
      final raw = await response.stream.toBytes();
      final bodyText = utf8.decode(raw, allowMalformed: true);
      await logger.logResponse(
        method: method,
        uri: uri,
        statusCode: response.statusCode,
        body: bodyText,
        elapsedMs: elapsed,
      );
      return http.StreamedResponse(
        http.ByteStream.fromBytes(raw),
        response.statusCode,
        contentLength: raw.length,
        request: request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } catch (e, st) {
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      await logger.logError(
        method: method,
        uri: uri,
        error: e,
        elapsedMs: elapsed,
        stackTrace: st,
      );
      rethrow;
    }
  }
}
