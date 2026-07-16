import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:http_parser/http_parser.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import 'api_logger.dart';

/// Talks to the Tamiva backend. Point [baseUrl] at your deployed API.
///
/// v36 changes:
///   - All mutating endpoints attach an `Idempotency-Key` header
///     (S3.18).
///   - Auth is via `x-user-id` header (S1.6).
///   - A global session event bus (`SessionEvents.bus`) lets any
///     widget react to a forced sign-out (S1.2).
///   - New `/auth/me` (S2.8) and `/payments/status` (S1.1 self-heal)
///     endpoints.
class ApiClient {
  final String baseUrl;
  final http.Client _http;

  static const _kShortTimeout = Duration(seconds: 15);
  static const _kLongTimeout = Duration(minutes: 5);
  static const _kUploadTimeout = Duration(minutes: 2);

  String? _userId;
  String? get currentUserId => _userId;

  void setUserId(String? id) {
    _userId = id;
  }

  static final _uuid = const Uuid();

  Map<String, String> _baseHeaders({String? idempotencyKey}) {
    final h = <String, String>{'Content-Type': 'application/json'};
    if (_userId != null) h['x-user-id'] = _userId!;
    if (idempotencyKey != null) h['Idempotency-Key'] = idempotencyKey;
    return h;
  }

  String _newIdempotencyKey([String? hint]) {
    return hint ?? _uuid.v4();
  }

  ApiClient({required this.baseUrl, http.Client? httpClient})
    : _http = LoggingHttpClient(httpClient ?? http.Client());

  Future<bool> sendOtp(String phone) async {
    final res = await _http.post(
      Uri.parse('$baseUrl/auth/otp/send'),
      headers: _baseHeaders(),
      body: jsonEncode({'phone': phone}),
    ).timeout(_kShortTimeout);
    _throwIfError(res, allowAnonymous: true);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['otpDisabled'] == true;
  }

  Future<void> verifyOtp({required String phone, required String code}) async {
    final res = await _http.post(
      Uri.parse('$baseUrl/auth/otp/verify'),
      headers: _baseHeaders(),
      body: jsonEncode({'phone': phone, 'code': code}),
    ).timeout(_kShortTimeout);
    _throwIfError(res, allowAnonymous: true);
  }

  Future<User> signup({
    required String fullName,
    required String phone,
    required String email,
    required String password,
    String? idempotencyKey,
  }) async {
    final res = await _http.post(
      Uri.parse('$baseUrl/auth/signup'),
      headers: _baseHeaders(idempotencyKey: _newIdempotencyKey(idempotencyKey)),
      body: jsonEncode({
        'fullName': fullName,
        'phone': phone,
        'email': email,
        'password': password,
      }),
    ).timeout(_kShortTimeout);
    _throwIfError(res, allowAnonymous: true);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return _userFromAuthBody(body, email: email, phone: phone);
  }

  Future<User> login({required String email, required String password}) async {
    final res = await _http.post(
      Uri.parse('$baseUrl/auth/login'),
      headers: _baseHeaders(),
      body: jsonEncode({'email': email, 'password': password}),
    ).timeout(_kShortTimeout);
    _throwIfError(res, allowAnonymous: true);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return _userFromAuthBody(body, email: email);
  }

  Future<User?> fetchMe() async {
    if (_userId == null) return null;
    try {
      final res = await _http.get(
        Uri.parse('$baseUrl/auth/me'),
        headers: _baseHeaders(),
      ).timeout(_kShortTimeout);
      if (res.statusCode == 401 || res.statusCode == 404) {
        return null;
      }
      _throwIfError(res);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return _userFromAuthBody(body, email: body['email'] as String? ?? '');
    } on TimeoutException {
      return null;
    } on ApiException {
      return null;
    }
  }

  Future<User?> refreshTier() async {
    if (_userId == null) return null;
    try {
      final res = await _http.get(
        Uri.parse('$baseUrl/payments/status'),
        headers: _baseHeaders(),
      ).timeout(_kShortTimeout);
      _throwIfError(res);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final tier = body['tier'] as String? ?? 'free';
      return User(
        id: _userId!,
        email: '',
        tier: tier,
        tierUpdatedAt: body['tierUpdatedAt'] is String
            ? DateTime.tryParse(body['tierUpdatedAt'] as String)
            : null,
        tierExpiresAt: body['tierExpiresAt'] is String
            ? DateTime.tryParse(body['tierExpiresAt'] as String)
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  User _userFromAuthBody(
    Map<String, dynamic> body, {
    required String email,
    String? phone,
  }) {
    return User(
      id: body['userId'] as String,
      email: email,
      fullName: body['fullName'] as String?,
      phone: phone,
      tier: body['tier'] as String? ?? 'free',
      tierUpdatedAt: body['tierUpdatedAt'] is String
          ? DateTime.tryParse(body['tierUpdatedAt'] as String)
          : null,
      tierExpiresAt: body['tierExpiresAt'] is String
          ? DateTime.tryParse(body['tierExpiresAt'] as String)
          : null,
    );
  }

  Future<User> upgradeToPro({required String userId}) async {
    final res = await _http.post(
      Uri.parse('$baseUrl/auth/upgrade/$userId'),
      headers: _baseHeaders(),
      body: jsonEncode({}),
    ).timeout(_kShortTimeout);
    _throwIfError(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return User(
      id: userId,
      email: body['email'] as String? ?? '',
      fullName: body['fullName'] as String?,
      tier: body['tier'] as String? ?? 'pro',
      tierUpdatedAt: body['tierUpdatedAt'] is String
          ? DateTime.tryParse(body['tierUpdatedAt'] as String)
          : null,
      tierExpiresAt: body['tierExpiresAt'] is String
          ? DateTime.tryParse(body['tierExpiresAt'] as String)
          : null,
    );
  }

  Future<RazorpayOrder> createRazorpayOrder({
    String? businessProfileId,
    String? idempotencyKey,
    String? plan,
  }) async {
    final res = await _http.post(
      Uri.parse('$baseUrl/payments/order'),
      headers: _baseHeaders(idempotencyKey: _newIdempotencyKey(idempotencyKey)),
      body: jsonEncode({
        if (businessProfileId != null) 'businessProfileId': businessProfileId,
        if (plan != null) 'plan': plan,
      }),
    ).timeout(_kShortTimeout);
    _throwIfError(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return RazorpayOrder(
      orderId: body['orderId'] as String,
      amount: (body['amount'] as num).toInt(),
      currency: body['currency'] as String? ?? 'INR',
      keyId: body['keyId'] as String,
      userId: body['userId'] as String,
      plan: body['plan'] as String?,
    );
  }

  Future<String> verifyRazorpayPayment({
    required String orderId,
    required String paymentId,
    required String signature,
  }) async {
    final res = await _http.post(
      Uri.parse('$baseUrl/payments/verify'),
      headers: _baseHeaders(),
      body: jsonEncode({
        'razorpay_order_id': orderId,
        'razorpay_payment_id': paymentId,
        'razorpay_signature': signature,
      }),
    ).timeout(_kShortTimeout);
    _throwIfError(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['tier'] as String? ?? 'pro';
  }

  Future<void> forgotPassword({required String email}) async {
    final res = await _http.post(
      Uri.parse('$baseUrl/auth/forgot-password'),
      headers: _baseHeaders(),
      body: jsonEncode({'email': email}),
    ).timeout(_kShortTimeout);
    _throwIfError(res, allowAnonymous: true);
  }

  Future<User> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final res = await _http.post(
      Uri.parse('$baseUrl/auth/reset-password'),
      headers: _baseHeaders(),
      body: jsonEncode({
        'email': email,
        'code': code,
        'newPassword': newPassword,
      }),
    ).timeout(_kShortTimeout);
    _throwIfError(res, allowAnonymous: true);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return _userFromAuthBody(body, email: email);
  }

  Future<BusinessProfile> createBusinessProfile({
    required String userId,
    required String name,
    required String industry,
    String? tagline,
    String? tone,
    String? palettePreference,
    String? fontPreference,
    List<String>? brandColors,
    String? targetAudience,
    String? idempotencyKey,
  }) async {
    final res = await _http.post(
      Uri.parse('$baseUrl/business-profiles'),
      headers: _baseHeaders(idempotencyKey: _newIdempotencyKey(idempotencyKey)),
      body: jsonEncode({
        'userId': userId,
        'name': name,
        'industry': industry,
        if (tagline != null) 'tagline': tagline,
        if (tone != null) 'tone': tone,
        if (palettePreference != null) 'palettePreference': palettePreference,
        if (fontPreference != null) 'fontPreference': fontPreference,
        if (brandColors != null) 'brandColors': brandColors,
        if (targetAudience != null) 'targetAudience': targetAudience,
      }),
    ).timeout(_kShortTimeout);
    _throwIfError(res);
    return BusinessProfile.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<BusinessProfile> updateBusinessProfile({
    required String userId,
    required String name,
    required String industry,
    String? tagline,
    String? tone,
    String? palettePreference,
    String? fontPreference,
    List<String>? photoUrls,
    List<String>? angleLabels,
  }) async {
    final res = await _http.put(
      Uri.parse('$baseUrl/business-profiles/by-user/$userId'),
      headers: _baseHeaders(),
      body: jsonEncode({
        'name': name,
        'industry': industry,
        if (tagline != null) 'tagline': tagline,
        if (tone != null) 'tone': tone,
        if (palettePreference != null) 'palettePreference': palettePreference,
        if (fontPreference != null) 'fontPreference': fontPreference,
        if (photoUrls != null) 'photoUrls': photoUrls,
        if (angleLabels != null) 'angleLabels': angleLabels,
      }),
    ).timeout(_kShortTimeout);
    _throwIfError(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return BusinessProfile.fromJson(body['profile'] as Map<String, dynamic>);
  }

  Future<Map<String, List<String>>> bulkGenerate({
    required String businessProfileId,
  }) async {
    final res = await _http.post(
      Uri.parse('$baseUrl/projects/bulk'),
      headers: _baseHeaders(),
      body: jsonEncode({'businessProfileId': businessProfileId}),
    ).timeout(_kShortTimeout);
    _throwIfError(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final ids = body['projectIds'] as Map<String, dynamic>;
    return {
      'logo': ((ids['logo'] as List<dynamic>?) ?? []).map((e) => e.toString()).toList(),
      'carousel': ((ids['carousel'] as List<dynamic>?) ?? []).map((e) => e.toString()).toList(),
      'video': ((ids['video'] as List<dynamic>?) ?? []).map((e) => e.toString()).toList(),
    };
  }

  Future<String> uploadPhoto(String filePath, {int? sizeBytes}) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/uploads'),
    );
    if (_userId != null) request.headers['x-user-id'] = _userId!;

    final mimeType = lookupMimeType(filePath) ?? 'image/jpeg';
    final parts = mimeType.split('/');

    request.files.add(await http.MultipartFile.fromPath(
      'photo',
      filePath,
      contentType: MediaType(parts[0], parts.length > 1 ? parts[1] : 'jpeg'),
    ));

    final streamed = await _http.send(request).timeout(_kUploadTimeout);
    final res = await http.Response.fromStream(streamed);
    _throwIfError(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['url'] as String;
  }

  Future<void> addAmbassadorPhotos({
    required String businessProfileId,
    required List<String> photoUrls,
    List<String>? angleLabels,
  }) async {
    final res = await _http.post(
      Uri.parse('$baseUrl/business-profiles/$businessProfileId/ambassadors'),
      headers: _baseHeaders(),
      body: jsonEncode({
        'photoUrls': photoUrls,
        if (angleLabels != null) 'angleLabels': angleLabels,
      }),
    ).timeout(_kShortTimeout);
    _throwIfError(res);
  }

  Future<String> createLogoProject({
    required String businessProfileId,
    required String stylePrompt,
    String? idempotencyKey,
  }) async {
    final res = await _http.post(
      Uri.parse('$baseUrl/projects/logo'),
      headers: _baseHeaders(idempotencyKey: _newIdempotencyKey(idempotencyKey)),
      body: jsonEncode({
        'businessProfileId': businessProfileId,
        'stylePrompt': stylePrompt,
      }),
    ).timeout(_kShortTimeout);
    _throwIfError(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['projectId'] as String;
  }

  Future<String> createCarouselProject({
    required String businessProfileId,
    String? topic,
    int slideCount = 5,
    String? idempotencyKey,
  }) async {
    final body = <String, dynamic>{
      'businessProfileId': businessProfileId,
      'slideCount': slideCount,
    };
    // Only include `topic` when non-null. The backend Zod schema treats
    // `topic: z.string().min(1).optional()` as accepting missing keys
    // but rejecting nulls - sending {"topic": null} triggers a 400.
    if (topic != null) body['topic'] = topic;

    final res = await _http.post(
      Uri.parse('$baseUrl/projects/carousel'),
      headers: _baseHeaders(idempotencyKey: _newIdempotencyKey(idempotencyKey)),
      body: jsonEncode(body),
    ).timeout(_kShortTimeout);
    _throwIfError(res);
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) {
      throw ApiException(200,
          'Expected {"projectId": "..."} but got ${decoded.runtimeType}.');
    }
    final projectId = decoded['projectId'];
    if (projectId is! String) {
      throw ApiException(200,
          'Response is missing the "projectId" field.');
    }
    return projectId;
  }

  Future<CreateVideoResult> createVideoProject({
    required String businessProfileId,
    String tier = 'draft',
    String? idempotencyKey,
  }) async {
    final res = await _http.post(
      Uri.parse('$baseUrl/projects/video'),
      headers: _baseHeaders(idempotencyKey: _newIdempotencyKey(idempotencyKey)),
      body: jsonEncode({
        'businessProfileId': businessProfileId,
        'tier': tier,
      }),
    ).timeout(_kShortTimeout);
    _throwIfError(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return CreateVideoResult(
      projectId: body['projectId'] as String,
      estimatedDurationSeconds: (body['conceptIndex'] as num?)?.toInt() ?? 5,
      referenceCount: 0,
    );
  }

  Future<BusinessProfile> getBusinessProfileById(String businessProfileId) async {
    final res = await _http.get(
      Uri.parse('$baseUrl/business-profiles/$businessProfileId'),
      headers: _baseHeaders(),
    ).timeout(_kShortTimeout);
    _throwIfError(res);
    return BusinessProfile.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<BusinessProfile?> getBusinessProfileByUser(String userId) async {
    final res = await _http.get(
      Uri.parse('$baseUrl/business-profiles/by-user/$userId'),
      headers: _baseHeaders(),
    ).timeout(_kShortTimeout);
    if (res.statusCode == 404) return null;
    _throwIfError(res);
    return BusinessProfile.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<BusinessProfileProjects> getBusinessProfileProjects(
    String businessProfileId,
  ) async {
    final res = await _http.get(
      Uri.parse('$baseUrl/business-profiles/$businessProfileId/projects'),
      headers: _baseHeaders(),
    ).timeout(_kShortTimeout);
    _throwIfError(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final projects = body['projects'] as Map<String, dynamic>;
    return BusinessProfileProjects(
      logo: _projectFromMap(projects['logo']),
      carousel: _projectFromMap(projects['carousel']),
      video: _projectFromMap(projects['video']),
    );
  }

  static Project? _projectFromMap(Object? raw) {
    if (raw == null) return null;
    return Project.fromJson(raw as Map<String, dynamic>);
  }

  Future<List<BusinessProfileProjectSummary>> getBusinessProfileHistory(
    String businessProfileId,
  ) async {
    final res = await _http.get(
      Uri.parse('$baseUrl/business-profiles/$businessProfileId/projects/all'),
      headers: _baseHeaders(),
    ).timeout(_kShortTimeout);
    _throwIfError(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final list = (body['projects'] as List<dynamic>)
        .map((p) => BusinessProfileProjectSummary.fromJson(
            p as Map<String, dynamic>))
        .toList();
    return list;
  }

  Future<Project> getProject(String projectId) async {
    final res = await _http.get(
      Uri.parse('$baseUrl/projects/$projectId'),
      headers: _baseHeaders(),
    ).timeout(_kShortTimeout);
    _throwIfError(res);
    return Project.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  void _throwIfError(http.Response res, {bool allowAnonymous = false}) {
    if (res.statusCode >= 400) {
      if (!allowAnonymous &&
          (res.statusCode == 401 || res.statusCode == 403)) {
        if (_userId != null) {
          _userId = null;
          SessionEvents.emit(const SessionExpired());
        }
      }
      throw ApiException(res.statusCode, res.body);
    }
  }
}

class ApiException implements Exception {
  final int statusCode;
  final String body;
  ApiException(this.statusCode, this.body);

  bool get isUpgradeableQuota {
    if (statusCode != 429) return false;
    try {
      final j = jsonDecode(body);
      return j is Map && j['upgradeCopy'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  String toString() => 'ApiException($statusCode): $body';
}

/// v36 / S1.2 — Session event bus.
class SessionEvents {
  static final _bus = _Bus();
  static Stream<SessionEvent> get stream => _bus.stream;
  static void emit(SessionEvent e) => _bus.add(e);
}

class _Bus {
  final _ctrl = StreamController<SessionEvent>.broadcast();
  Stream<SessionEvent> get stream => _ctrl.stream;
  void add(SessionEvent e) => _ctrl.add(e);
}

sealed class SessionEvent {
  const SessionEvent();
}

class SessionExpired extends SessionEvent {
  const SessionExpired();
}

class CreateVideoResult {
  final String projectId;
  final int estimatedDurationSeconds;
  final int referenceCount;

  CreateVideoResult({
    required this.projectId,
    required this.estimatedDurationSeconds,
    required this.referenceCount,
  });
}

class BusinessProfileProjects {
  final Project? logo;
  final Project? carousel;
  final Project? video;

  BusinessProfileProjects({
    required this.logo,
    required this.carousel,
    required this.video,
  });
}

class BusinessProfileProjectSummary {
  final String id;
  final String type;
  final String status;
  final String createdAt;
  final String updatedAt;
  final int assetCount;
  final String? firstAssetUrlSample;
  final int durationSeconds;
  final List<BusinessProfileJobSummary> jobs;

  BusinessProfileProjectSummary({
    required this.id,
    required this.type,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.assetCount,
    required this.firstAssetUrlSample,
    required this.durationSeconds,
    required this.jobs,
  });

  factory BusinessProfileProjectSummary.fromJson(
      Map<String, dynamic> json) {
    return BusinessProfileProjectSummary(
      id: json['id'] as String,
      type: json['type'] as String,
      status: json['status'] as String,
      createdAt: json['createdAt'] as String? ?? '',
      updatedAt: json['updatedAt'] as String? ?? '',
      assetCount: (json['assetCount'] as num?)?.toInt() ?? 0,
      firstAssetUrlSample: json['firstAssetUrlSample'] as String?,
      durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
      jobs: ((json['jobs'] as List<dynamic>?) ?? const [])
          .map((j) => BusinessProfileJobSummary.fromJson(
              j as Map<String, dynamic>))
          .toList(),
    );
  }
}

class BusinessProfileJobSummary {
  final String stage;
  final String provider;
  final String status;
  final String? error;

  BusinessProfileJobSummary({
    required this.stage,
    required this.provider,
    required this.status,
    this.error,
  });

  factory BusinessProfileJobSummary.fromJson(Map<String, dynamic> json) {
    return BusinessProfileJobSummary(
      stage: json['stage'] as String,
      provider: json['provider'] as String,
      status: json['status'] as String,
      error: json['error'] as String?,
    );
  }
}

class RazorpayOrder {
  final String orderId;
  final int amount; // in paise
  final String currency;
  final String keyId;
  final String userId;
  // v37: server echoes the resolved plan so callers can show the right
  // post-purchase confirmation without re-resolving it.
  final String? plan;

  const RazorpayOrder({
    required this.orderId,
    required this.amount,
    required this.currency,
    required this.keyId,
    required this.userId,
    this.plan,
  });
}
