import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:http_parser/http_parser.dart';
import '../models/models.dart';

/// Talks to the Tamiva backend. Point [baseUrl] at your deployed API -
/// during local development this is typically http://10.0.2.2:4000
/// (Android emulator's alias for the host machine's localhost).
class ApiClient {
  final String baseUrl;
  final http.Client _http;

  /// Timeout for normal HTTP calls (auth, create project, status polls).
  static const _kShortTimeout = Duration(seconds: 15);

  /// Timeout for long polls (status checks while a generation is in
  /// flight). Generations can take 60-90s, so the poll itself can
  /// legitimately be slow.
  static const _kLongTimeout = Duration(minutes: 5);

  ApiClient({required this.baseUrl, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  Future<http.Response> _post(Uri url, {Object? body, Map<String, String>? headers}) {
    return _http.post(url, headers: headers, body: body).timeout(_kShortTimeout);
  }

  Future<http.Response> _get(Uri url, {Map<String, String>? headers}) {
    return _http.get(url, headers: headers).timeout(_kShortTimeout);
  }

  Future<http.StreamedResponse> _send(http.BaseRequest request) {
    return _http.send(request).timeout(_kLongTimeout);
  }

  /// Returns true if the phone was auto-verified because OTP is currently
  /// disabled on the backend (see OTP_DISABLED on the API service) - in
  /// that case the caller can skip showing the code-entry sheet.
  Future<bool> sendOtp(String phone) async {
    final res = await _post(
      Uri.parse('$baseUrl/auth/otp/send'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone': phone}),
    );
    _throwIfError(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['otpDisabled'] == true;
  }

  Future<void> verifyOtp({required String phone, required String code}) async {
    final res = await _post(
      Uri.parse('$baseUrl/auth/otp/verify'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone': phone, 'code': code}),
    );
    _throwIfError(res);
  }

  /// Returns the User record (now includes tier + tierUpdatedAt).
  /// Use this instead of the older signup that returned userId only.
  Future<User> signup({
    required String fullName,
    required String phone,
    required String email,
    required String password,
  }) async {
    final res = await _post(
      Uri.parse('$baseUrl/auth/signup'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'fullName': fullName,
        'phone': phone,
        'email': email,
        'password': password,
      }),
    );
    _throwIfError(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return User(
      id: body['userId'] as String,
      email: email,
      fullName: body['fullName'] as String?,
      phone: phone,
      tier: body['tier'] as String? ?? 'free',
      tierUpdatedAt: body['tierUpdatedAt'] is String
          ? DateTime.tryParse(body['tierUpdatedAt'] as String)
          : null,
    );
  }

  Future<User> login({required String email, required String password}) async {
    final res = await _post(
      Uri.parse('$baseUrl/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    _throwIfError(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return User(
      id: body['userId'] as String,
      email: email,
      fullName: body['fullName'] as String?,
      tier: body['tier'] as String? ?? 'free',
      tierUpdatedAt: body['tierUpdatedAt'] is String
          ? DateTime.tryParse(body['tierUpdatedAt'] as String)
          : null,
    );
  }

  /// Mock payment confirmation. Sets user.tier='pro' and returns the
  /// updated user. In v24 this is a no-op endpoint that the admin
  /// can also call directly via /admin/users/:userId/tier.
  Future<User> upgradeToPro({required String userId}) async {
    final res = await _post(
      Uri.parse('$baseUrl/auth/upgrade/$userId'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({}),
    );
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
    );
  }

  /// Kicks off a password reset - sends a 6-digit code to the user's
  /// email if the account exists.
  Future<void> forgotPassword({required String email}) async {
    final res = await _post(
      Uri.parse('$baseUrl/auth/forgot-password'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email}),
    );
    _throwIfError(res);
  }

  /// Resets password; returns the new user record (which the app can
  /// use to auto-sign-in).
  Future<User> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final res = await _post(
      Uri.parse('$baseUrl/auth/reset-password'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email,
        'code': code,
        'newPassword': newPassword,
      }),
    );
    _throwIfError(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return User(
      id: body['userId'] as String,
      email: email,
      fullName: body['fullName'] as String?,
      tier: body['tier'] as String? ?? 'free',
      tierUpdatedAt: body['tierUpdatedAt'] is String
          ? DateTime.tryParse(body['tierUpdatedAt'] as String)
          : null,
    );
  }

  Future<BusinessProfile> createBusinessProfile({
    required String userId,
    required String name,
    required String industry,
    String? tagline,
    String? tone,
    // v24: CSV keys for palette + font preferences.
    String? palettePreference,
    String? fontPreference,
    List<String>? brandColors,
    String? targetAudience,
  }) async {
    final res = await _post(
      Uri.parse('$baseUrl/business-profiles'),
      headers: {'Content-Type': 'application/json'},
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
    );
    _throwIfError(res);
    return BusinessProfile.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// v24: Pro users only. Replaces the business profile text + photos
  /// and triggers a new regeneration cycle. Returns the updated profile.
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
      headers: {'Content-Type': 'application/json'},
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

  /// v24: kicks off the bulk regeneration. Returns a map of project
  /// ids per type so the status board can subscribe.
  Future<Map<String, List<String>>> bulkGenerate({
    required String businessProfileId,
  }) async {
    final res = await _post(
      Uri.parse('$baseUrl/projects/bulk'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'businessProfileId': businessProfileId}),
    );
    _throwIfError(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final ids = body['projectIds'] as Map<String, dynamic>;
    return {
      'logo': ((ids['logo'] as List<dynamic>?) ?? []).map((e) => e.toString()).toList(),
      'carousel': ((ids['carousel'] as List<dynamic>?) ?? []).map((e) => e.toString()).toList(),
      'video': ((ids['video'] as List<dynamic>?) ?? []).map((e) => e.toString()).toList(),
    };
  }

  /// Uploads a single photo file and returns its public URL.
  Future<String> uploadPhoto(String filePath) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/uploads'));

    final mimeType = lookupMimeType(filePath) ?? 'image/jpeg';
    final parts = mimeType.split('/');

    request.files.add(await http.MultipartFile.fromPath(
      'photo',
      filePath,
      contentType: MediaType(parts[0], parts.length > 1 ? parts[1] : 'jpeg'),
    ));

    final streamed = await _send(request);
    final res = await http.Response.fromStream(streamed);
    _throwIfError(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['url'] as String;
  }

  Future<void> addAmbassadorPhotos({
    required String businessProfileId,
    required List<String> photoUrls,
    List<String>? angleLabels,
  }) async {
    final res = await _post(
      Uri.parse('$baseUrl/business-profiles/$businessProfileId/ambassadors'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'photoUrls': photoUrls,
        if (angleLabels != null) 'angleLabels': angleLabels,
      }),
    );
    _throwIfError(res);
  }

  /// Kicks off logo generation. Returns the new project id; poll
  /// [getProject] until status is "ready".
  Future<String> createLogoProject({
    required String businessProfileId,
    required String stylePrompt,
  }) async {
    final res = await _post(
      Uri.parse('$baseUrl/projects/logo'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'businessProfileId': businessProfileId,
        'stylePrompt': stylePrompt,
      }),
    );
    _throwIfError(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['projectId'] as String;
  }

  /// Kicks off a 5-slide Brand Story carousel render.
  Future<String> createCarouselProject({
    required String businessProfileId,
    String? topic,
    int slideCount = 5,
  }) async {
    final res = await _post(
      Uri.parse('$baseUrl/projects/carousel'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'businessProfileId': businessProfileId,
        'topic': topic,
        'slideCount': slideCount,
      }),
    );
    _throwIfError(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['projectId'] as String;
  }

  /// Kicks off a 10-second brand film render.
  Future<CreateVideoResult> createVideoProject({
    required String businessProfileId,
    String tier = 'draft',
  }) async {
    final res = await _post(
      Uri.parse('$baseUrl/projects/video'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'businessProfileId': businessProfileId,
        'tier': tier,
      }),
    );
    _throwIfError(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return CreateVideoResult(
      projectId: body['projectId'] as String,
      estimatedDurationSeconds: (body['conceptIndex'] as num?)?.toInt() ?? 5,
      referenceCount: 0,
    );
  }

  /// Returns the business profile by id, or throws on 404. Used by
  /// the brand-assets screen to read palette/font preferences.
  Future<BusinessProfile> getBusinessProfileById(String businessProfileId) async {
    final res = await _get(
      Uri.parse('$baseUrl/business-profiles/$businessProfileId'),
    );
    _throwIfError(res);
    return BusinessProfile.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<BusinessProfile?> getBusinessProfileByUser(String userId) async {
    final res = await _get(
      Uri.parse('$baseUrl/business-profiles/by-user/$userId'),
    );
    if (res.statusCode == 404) return null;
    _throwIfError(res);
    return BusinessProfile.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<BusinessProfileProjects> getBusinessProfileProjects(
    String businessProfileId,
  ) async {
    final res = await _get(
      Uri.parse('$baseUrl/business-profiles/$businessProfileId/projects'),
    );
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
    final res = await _get(
      Uri.parse('$baseUrl/business-profiles/$businessProfileId/projects/all'),
    );
    _throwIfError(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final list = (body['projects'] as List<dynamic>)
        .map((p) => BusinessProfileProjectSummary.fromJson(
            p as Map<String, dynamic>))
        .toList();
    return list;
  }

  Future<Project> getProject(String projectId) async {
    final res = await _get(Uri.parse('$baseUrl/projects/$projectId'));
    _throwIfError(res);
    return Project.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  void _throwIfError(http.Response res) {
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, res.body);
    }
  }
}

class ApiException implements Exception {
  final int statusCode;
  final String body;
  ApiException(this.statusCode, this.body);

  @override
  String toString() => 'ApiException($statusCode): $body';
}

/// What /projects/video returns. Lets the UI show an ETA pill.
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
