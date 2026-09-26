import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';

void main() {
  test('legacy profiles without a scope keep the connection root', () {
    final envelope = _envelope();
    final profile = VelockSyncProfile.fromEnvelope(envelope);

    expect(profile.remoteRootSegments, isEmpty);
    expect(
      profile.toEnvelope().dataset.containsKey('remoteRootSegments'),
      isFalse,
    );
  });

  test('round-trips decoded scope segments through JSON once', () {
    final profile = _profile(
      remoteRootSegments: const ['中文 空格', '%', '#', '?'],
    );
    final json = jsonDecode(jsonEncode(profile.toEnvelope().toJson()));
    final restored = VelockSyncProfile.fromEnvelope(
      SyncProfileEnvelope.fromJson(json as Map<String, dynamic>),
    );

    expect(restored.remoteRootSegments, ['中文 空格', '%', '#', '?']);
    expect(restored.toEnvelope().dataset['remoteRootSegments'], [
      '中文 空格',
      '%',
      '#',
      '?',
    ]);
  });

  test('defensively copies the scope and preserves it through copyWith', () {
    final source = <String>['folder'];
    final profile = _profile(remoteRootSegments: source);
    source.add('mutated');

    expect(profile.remoteRootSegments, ['folder']);
    expect(
      () => profile.remoteRootSegments.add('mutated'),
      throwsUnsupportedError,
    );

    final copied = profile.copyWith(remoteRootSegments: const ['nested']);
    expect(profile.remoteRootSegments, ['folder']);
    expect(copied.remoteRootSegments, ['nested']);
    expect(profile.copyWith().remoteRootSegments, ['folder']);
  });

  for (final invalid in <Object?>[
    null,
    'folder',
    <Object?>[''],
    ['.'],
    ['..'],
    ['a/b'],
    ['a\\b'],
    ['line\nbreak'],
    ['ok', 1],
  ]) {
    test('rejects invalid supplied scope ${invalid.runtimeType}: $invalid', () {
      final envelope = _envelope(remoteRootSegments: invalid);
      expect(
        () => VelockSyncProfile.fromEnvelope(envelope),
        throwsFormatException,
      );
    });
  }

  test('rejects invalid segments when constructing a new profile', () {
    for (final invalid in <String>['', '.', '..', 'a/b', 'a\\b', 'a\tb']) {
      expect(
        () => _profile(remoteRootSegments: [invalid]),
        throwsFormatException,
      );
    }
  });
}

VelockSyncProfile _profile({List<String> remoteRootSegments = const []}) =>
    VelockSyncProfile(
      profileId: 'profile-1',
      datasetId: 'dataset-1',
      vaultId: 'vault-1',
      deviceId: 'device-1',
      displayName: 'Velock vault',
      connectionId: 'connection-1',
      pairedProducerId: 'producer-1',
      pairedProducerPublicKeyId: 'key-1',
      exchangeBindingId: 'binding-1',
      remoteRootSegments: remoteRootSegments,
      backgroundPolicy: const SyncProfileBackgroundPolicy(),
      state: SyncProfileState.active,
      createdAt: DateTime.utc(2026, 9, 26),
    );

SyncProfileEnvelope _envelope({Object? remoteRootSegments = _unset}) =>
    SyncProfileEnvelope(
      kind: SyncDatasetKind.velockManaged,
      profileId: 'profile-1',
      datasetId: 'dataset-1',
      vaultId: 'vault-1',
      deviceId: 'device-1',
      displayName: 'Velock vault',
      connectionId: 'connection-1',
      state: SyncProfileState.active,
      backgroundPolicy: const SyncProfileBackgroundPolicy(),
      dataset: {
        'pairedProducerId': 'producer-1',
        'pairedProducerPublicKeyId': 'key-1',
        'exchangeBindingId': 'binding-1',
        'trustedProducerIds': const ['producer-1'],
        if (!identical(remoteRootSegments, _unset))
          'remoteRootSegments': remoteRootSegments,
      },
      createdAt: DateTime.utc(2026, 9, 26),
    );

const _unset = Object();
