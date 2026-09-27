import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
import 'dart:async';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';

/// Separate from upload/download locks: protects the destination from the
/// first profile read through completion, including pre-run remote requests.
Future<T> withVelockLocationGuard<T>(
  SyncStateDatabase database,
  String profileId,
  Future<T> Function() action,
) async {
  final key = 'velock-location:$profileId';
  final owner = const Uuid().v4();
  if (!await database.tryAcquireProfileLock(
    profileId: key,
    owner: owner,
    now: DateTime.now().toUtc(),
    staleAfter: const Duration(minutes: 5),
  )) {
    throw SyncRunBusyException(profileId);
  }
  Future<void> heartbeat = Future.value();
  final timer = Timer.periodic(const Duration(seconds: 30), (_) {
    heartbeat = heartbeat.then((_) async {
      await database.heartbeatProfileLock(
        profileId: key,
        owner: owner,
        now: DateTime.now().toUtc(),
      );
    });
  });
  try {
    return await action();
  } finally {
    timer.cancel();
    try {
      await heartbeat;
    } finally {
      await database.releaseProfileLock(profileId: key, owner: owner);
    }
  }
}
