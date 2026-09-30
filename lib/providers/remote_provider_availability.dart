import 'package:hooks_riverpod/hooks_riverpod.dart' show Provider;
import 'package:velock_sync/providers/oauth/oauth_public_client_configuration.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Which remote location types this build can set up without any extra step.
///
/// - WebDAV is always available.
/// - Google Drive, OneDrive, Baidu Netdisk and Aliyun Drive are ready when the
///   build carries an OAuth registration for them (`--dart-define`; Baidu also
///   needs its SecretKey). The repository ships none, so a self-built copy has
///   none unless its builder adds their own.
/// - Any OAuth type without one can still be connected with the user's own
///   app registration ([needsOwnRegistration]); such types are listed apart
///   so nobody reaches a dead end by accident.
///
/// A type is never hidden from lists of connections that already exist.
class RemoteProviderAvailability {
  const RemoteProviderAvailability({required this.creatable});

  /// Availability for the running build.
  factory RemoteProviderAvailability.forBuild({
    bool Function(RemoteProviderType)? hasBuiltInClientId,
  }) {
    final configured =
        hasBuiltInClientId ??
        OAuthPublicClientConfiguration.hasBuiltInRegistration;
    return RemoteProviderAvailability(
      creatable: {
        RemoteProviderType.webDav,
        for (final type in oauthProviderTypes)
          if (configured(type)) type,
      },
    );
  }

  static const oauthProviderTypes = [
    RemoteProviderType.googleDrive,
    RemoteProviderType.oneDrive,
    RemoteProviderType.baiduNetdisk,
    RemoteProviderType.aliyunDrive,
  ];

  /// Types that work out of the box in this build, in display order.
  final Set<RemoteProviderType> creatable;

  bool canCreate(RemoteProviderType type) => creatable.contains(type);

  /// OAuth types this build has no registration for. They can only be
  /// connected with an app the user registered on that provider themselves.
  List<RemoteProviderType> get needsOwnRegistration => [
    for (final type in oauthProviderTypes)
      if (!creatable.contains(type)) type,
  ];

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
