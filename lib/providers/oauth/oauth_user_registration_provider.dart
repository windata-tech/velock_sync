import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/providers/oauth/oauth_client_registration.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// The user's own app registration for one provider, read from secure
/// storage. Invalidate after saving or removing one.
final oauthUserRegistrationProvider = FutureProvider.autoDispose
    .family<OAuthClientRegistration?, RemoteProviderType>(
      (ref, type) =>
          ref.watch(credentialStoreProvider).readOAuthClientRegistration(type),
    );
