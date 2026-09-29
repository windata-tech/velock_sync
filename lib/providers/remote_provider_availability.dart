import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:hooks_riverpod/hooks_riverpod.dart' show Provider;
import 'package:velock_sync/providers/oauth/oauth_public_client_configuration.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Which remote location types this build can actually set up.
///
/// Only types that can finish a real connection are offered when adding a
/// connection. A type is never hidden from lists of connections that already
/// exist; those stay listable, editable and deletable.
///
/// - WebDAV is always available.
/// - Google Drive / OneDrive need a public OAuth client ID supplied at build
///   time (`--dart-define`). Debug builds also offer them so developers can
///   reach the developer Client ID form; release builds never do.
/// - Baidu Netdisk and Aliyun Drive have no storage adapter in this build.
class RemoteProviderAvailability {
  const RemoteProviderAvailability({
    required this.creatable,
    required this.allowsDeveloperClientId,
  });

  /// Availability for the running build.
  factory RemoteProviderAvailability.forBuild({
    bool developerMode = kDebugMode,
    bool Function(RemoteProviderType)? hasBuiltInClientId,
  }) {
    final configured =
        hasBuiltInClientId ??
        OAuthPublicClientConfiguration.hasBuiltInRegistration;
    return RemoteProviderAvailability(
      creatable: {
        RemoteProviderType.webDav,
        for (final type in const [
          RemoteProviderType.googleDrive,
          RemoteProviderType.oneDrive,
        ])
          if (developerMode || configured(type)) type,
      },
      allowsDeveloperClientId: developerMode,
    );
  }

  /// Types a user may pick when adding a new connection, in display order.
  final Set<RemoteProviderType> creatable;

  /// Whether the developer-only Client ID form (and a Client ID saved through
  /// it) may be used. Always false in release builds.
  final bool allowsDeveloperClientId;

  bool canCreate(RemoteProviderType type) => creatable.contains(type);

  /// Creatable types in the fixed order used by pickers and summaries.
  List<RemoteProviderType> get ordered => [
    for (final type in RemoteProviderType.values)
      if (creatable.contains(type)) type,
  ];

  /// Human-readable list such as "WebDAV, Google Drive, or OneDrive".
  String describe({required bool chinese}) {
    final names = [for (final type in ordered) remoteProviderDisplayName(type)];
    if (names.length <= 1) return names.join();
    final head = names.sublist(0, names.length - 1);
    if (chinese) return '${head.join('、')} 或 ${names.last}';
    return names.length == 2
        ? '${head.single} or ${names.last}'
        : '${head.join(', ')}, or ${names.last}';
  }
}

/// Product names are proper nouns and stay the same in every locale.
String remoteProviderDisplayName(RemoteProviderType type) => switch (type) {
  RemoteProviderType.webDav => 'WebDAV',
  RemoteProviderType.googleDrive => 'Google Drive',
  RemoteProviderType.oneDrive => 'OneDrive',
  RemoteProviderType.baiduNetdisk => 'Baidu Netdisk',
  RemoteProviderType.aliyunDrive => 'Aliyun Drive',
};

final remoteProviderAvailabilityProvider = Provider<RemoteProviderAvailability>(
  (ref) => RemoteProviderAvailability.forBuild(),
);
