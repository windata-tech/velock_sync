import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/background/foreground_sync_coordinator.dart';

void main() {
  test('runs opted-in profiles after network recovers from offline', () async {
    final changes = StreamController<List<ConnectivityResult>>();
    addTearDown(changes.close);
    var runs = 0;
    final coordinator = ForegroundSyncCoordinator(
      runProfiles: () async {
        runs++;
        return true;
      },
      connectivityChanges: changes.stream,
    )..start();
    addTearDown(coordinator.dispose);

    changes.add(const [ConnectivityResult.none]);
    await Future<void>.delayed(Duration.zero);
    changes.add(const [ConnectivityResult.wifi]);
    await Future<void>.delayed(Duration.zero);

    expect(runs, 1);
  });

  test(
    'serializes overlapping lifecycle triggers into one queued rerun',
    () async {
      final first = Completer<bool>();
      var runs = 0;
      final coordinator = ForegroundSyncCoordinator(
        runProfiles: () {
          runs++;
          return runs == 1 ? first.future : Future.value(true);
        },
      );
      addTearDown(coordinator.dispose);

      final initial = coordinator.onAppResumed();
      await Future<void>.delayed(Duration.zero);
      final overlapping = coordinator.onAppResumed();
      first.complete(true);
      await Future.wait([initial, overlapping]);

      expect(runs, 2);
    },
  );
}
