import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

/// The V1 provider contract identifiers from section 12.3 of
/// `docs/V1_COMPLETION_SPEC.md`.
enum ObjectStoreContract {
  zeroByteRoundTrip('zero_byte_round_trip'),
  smallObjectRoundTrip('small_object_round_trip'),
  largeStreamingWrite('large_streaming_write'),
  interruptedImmutableSafeRetry('interrupted_immutable_safe_retry'),
  immutableCollision('immutable_collision'),
  paginationDeduplication('pagination_deduplication'),
  notFoundMapping('not_found_mapping'),
  authorizationRecovery('authorization_recovery'),
  rateLimitCancellation('rate_limit_cancellation'),
  transferIntegrity('transfer_integrity'),
  unicodeLogicalKey('unicode_logical_key'),
  idempotentDelete('idempotent_delete'),
  cancellationCleanup('cancellation_cleanup'),
  quotaMapping('quota_mapping'),
  traversalRejection('traversal_rejection'),
  redactedErrors('redacted_errors');

  const ObjectStoreContract(this.id);

  final String id;
}

/// Declares deliberate safe fallbacks rather than using `skip` for a provider
/// capability that is unavailable (for example, WebDAV resumable uploads).
class ObjectStoreContractCapabilities {
  const ObjectStoreContractCapabilities({
    required this.supportsResumableUpload,
    required this.authorizationMode,
  });

  final bool supportsResumableUpload;
  final ObjectStoreAuthorizationMode authorizationMode;
}

enum ObjectStoreAuthorizationMode { oauthRefresh, reauthorizationRequired }

typedef ObjectStoreContractCheck =
    Future<void> Function(RemoteObjectStore store);

/// Fixture implemented beside each real provider's scripted Dio tests.
///
/// Every contract must have a concrete check. The common suite fails at test
/// registration time if a provider attempts to omit a contract.
abstract interface class ObjectStoreContractFixture {
  String get providerName;

  ObjectStoreContractCapabilities get capabilities;

  /// Constructs the actual provider adapter backed by scripted HTTP, never a
  /// live credential or cloud account.
  Future<RemoteObjectStore> createStore();

  Future<void> reset();

  /// Configures only the scripted transport for [contract], before the actual
  /// adapter is constructed. This keeps each contract isolated without live
  /// provider state.
  Future<void> arrange(ObjectStoreContract contract);

  Map<ObjectStoreContract, ObjectStoreContractCheck> get checks;
}
