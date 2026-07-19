import 'dart:async';

import 'package:dio/dio.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

/// Bridges the provider-neutral operation signal to Dio without exposing Dio
/// types in the sync-core contract.
CancelToken? dioCancelTokenFor(RemoteOperationCancellation? cancellation) {
  if (cancellation == null) return null;
  final token = CancelToken();
  if (cancellation.isCancelled) {
    token.cancel();
  } else {
    unawaited(cancellation.whenCancelled.then<void>((_) => token.cancel()));
  }
  return token;
}
