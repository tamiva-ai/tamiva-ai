class BusinessProfile {
  final String id;
  final String name;
  final String industry;
  final String? tagline;
  final String? tone;
  // v24: two new free / pro input fields (CSV strings).
  final String? palettePreference;
  final String? fontPreference;

  BusinessProfile({
    required this.id,
    required this.name,
    required this.industry,
    this.tagline,
    this.tone,
    this.palettePreference,
    this.fontPreference,
  });

  factory BusinessProfile.fromJson(Map<String, dynamic> json) {
    return BusinessProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      industry: json['industry'] as String,
      tagline: json['tagline'] as String?,
      tone: json['tone'] as String?,
      palettePreference: json['palettePreference'] as String?,
      fontPreference: json['fontPreference'] as String?,
    );
  }
}

class ProjectAsset {
  final String id;
  final String type; // logo_variant | video_final | carousel_slide
  final int? slideIndex;
  final String url;

  ProjectAsset({
    required this.id,
    required this.type,
    required this.url,
    this.slideIndex,
  });

  factory ProjectAsset.fromJson(Map<String, dynamic> json) {
    return ProjectAsset(
      id: json['id'] as String,
      type: json['type'] as String,
      url: json['url'] as String,
      slideIndex: json['slideIndex'] as int?,
    );
  }
}

class User {
  final String id;
  final String email;
  final String? fullName;
  final String? phone;
  // v36: tier system. Server returns the current tier so the app can
  // branch UI without trusting local state. tierExpiresAt is the
  // server-authoritative Pro expiration — used by the client only to
  // decide whether to re-query /payments/status.
  final String tier; // 'free' | 'pro'
  final DateTime? tierUpdatedAt;
  final DateTime? tierExpiresAt;

  User({
    required this.id,
    required this.email,
    this.fullName,
    this.phone,
    this.tier = 'free',
    this.tierUpdatedAt,
    this.tierExpiresAt,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String,
      email: json['email'] as String,
      fullName: json['fullName'] as String?,
      phone: json['phone'] as String?,
      tier: (json['tier'] as String?) ?? 'free',
      tierUpdatedAt: json['tierUpdatedAt'] is String
          ? DateTime.tryParse(json['tierUpdatedAt'] as String)
          : null,
      tierExpiresAt: json['tierExpiresAt'] is String
          ? DateTime.tryParse(json['tierExpiresAt'] as String)
          : null,
    );
  }

  /// True when the user is on any paid tier (launch / pro / premium).
  /// Use this for paid-feature gating. Use [tier] directly when the UI
  /// needs to show plan-specific copy.
  bool get isPaid => tier != 'free' && tier.isNotEmpty;

  /// Kept for back-compat with code paths that only care about Pro.
  /// Prefer [isPaid] for new gating checks.
  bool get isPro => tier == 'pro';
}

class Project {
  final String id;
  final String type;
  final String status; // draft|queued|generating|rendering|ready|failed
  final List<ProjectAsset> assets;
  final DateTime? createdAt;

  Project({
    required this.id,
    required this.type,
    required this.status,
    required this.assets,
    this.createdAt,
  });

  factory Project.fromJson(Map<String, dynamic> raw) {
    final json = raw;
    return Project(
      id: json['id'] as String,
      type: json['type'] as String,
      status: json['status'] as String,
      assets: (json['assets'] as List<dynamic>? ?? [])
          .map((a) => ProjectAsset.fromJson(a as Map<String, dynamic>))
          .toList(),
      createdAt: json['createdAt'] is String
          ? DateTime.tryParse(json['createdAt'] as String)
          : null,
    );
  }

  bool get isReady => status == 'ready';
  bool get isFailed => status == 'failed';
  bool get isInProgress => !isReady && !isFailed;

  Duration elapsedSinceCreation(DateTime now) {
    final start = createdAt ?? now;
    return now.difference(start);
  }
}
