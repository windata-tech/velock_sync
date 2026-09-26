// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/cloud_backup/application/backup_destination_service.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace.dart';
import 'package:velock_sync/infrastructure/staging/staging_space_manager.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/sync_profiles/settings/sync_settings_service.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_pairing_session.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_profile_finalizer.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VelockWizardSessionController recovery state', () {
    late _SignedFixture fixture;

    setUp(() async {
      fixture = await _SignedFixture.create(base: DateTime.utc(2026, 9, 26, 8));
    });

    test(
      'invalidates an approval while preserving selection and recovery flag',
      () async {
        final session = fixture.session(requestId: 'request-1');
        final approval = await fixture.approvalFor(session);
        final container = _controllerContainer(clock: () => fixture.base);
        addTearDown(container.dispose);
        final controller = container.read(velockWizardSessionProvider.notifier);

        controller.sessionStarted(session);
        controller.connectionSelected('connection-restore');
        controller.approved(approval);
        controller.connectionMissing();

        controller.authorizationInvalidated(
          session,
          VelockWizardAuthorizationProblem.expired,
        );

        final state = container.read(velockWizardSessionProvider);
        expect(
          state.authorizationProblem,
          VelockWizardAuthorizationProblem.expired,
        );
        expect(state.session, isNull);
        expect(state.approval, isNull);
        expect(state.selectedConnectionId, 'connection-restore');
        expect(state.connectionNeeded, isTrue);
      },
    );

    test(
      'a stale invalidation cannot clear a newer session or selection',
      () async {
        final oldSession = fixture.session(requestId: 'old-request');
        final newSession = fixture.session(requestId: 'new-request');
        final oldApproval = await fixture.approvalFor(oldSession);
        final newApproval = await fixture.approvalFor(newSession);
        final container = _controllerContainer(clock: () => fixture.base);
        addTearDown(container.dispose);
        final controller = container.read(velockWizardSessionProvider.notifier);

        controller.sessionStarted(oldSession);
        controller.connectionSelected('old-connection');
        controller.approved(oldApproval);
        controller.sessionStarted(newSession);
        controller.connectionSelected('new-connection');
        controller.approved(newApproval);

        controller.authorizationInvalidated(
          oldSession,
          VelockWizardAuthorizationProblem.expired,
        );

        final state = container.read(velockWizardSessionProvider);
        expect(state.authorizationProblem, isNull);
        expect(state.session?.request.requestId, 'new-request');
        expect(state.approval?.requestId, 'new-request');
        expect(state.selectedConnectionId, 'new-connection');
      },
    );

    test(
      'uses the earliest request or approval expiry and clears approval',
      () async {
        final session = fixture.session(
          requestId: 'timer-request',
          ttl: const Duration(minutes: 2),
        );
        final approval = await fixture.approvalFor(
          session,
          expiresAt: fixture.base.add(const Duration(minutes: 4)),
        );

        fakeAsync((async) {
          final container = _controllerContainer(
            clock: () => fixture.base.add(async.elapsed),
          );
          final controller = container.read(
            velockWizardSessionProvider.notifier,
          );

          controller.sessionStarted(session);
          controller.approved(approval);
          expect(async.pendingTimers, hasLength(1));

          async.elapse(const Duration(minutes: 1, seconds: 59));
          expect(
            container.read(velockWizardSessionProvider).authorizationProblem,
            isNull,
          );

          async.elapse(const Duration(seconds: 1));
          final state = container.read(velockWizardSessionProvider);
          expect(
            state.authorizationProblem,
            VelockWizardAuthorizationProblem.expired,
          );
          expect(state.session, isNull);
          expect(state.approval, isNull);
          expect(async.pendingTimers, isEmpty);

          container.dispose();
        });
      },
    );

    test(
      'uses the approval expiry when it expires before the request',
      () async {
        final session = fixture.session(
          requestId: 'response-timer-request',
          ttl: const Duration(minutes: 5),
        );
        final approval = await fixture.approvalFor(
          session,
          expiresAt: fixture.base.add(const Duration(minutes: 2)),
        );

        fakeAsync((async) {
          final container = _controllerContainer(
            clock: () => fixture.base.add(async.elapsed),
          );
          final controller = container.read(
            velockWizardSessionProvider.notifier,
          );

          controller.sessionStarted(session);
          controller.approved(approval);
          expect(async.pendingTimers, hasLength(1));

          async.elapse(const Duration(minutes: 1, seconds: 59));
          expect(
            container.read(velockWizardSessionProvider).authorizationProblem,
            isNull,
          );

          async.elapse(const Duration(seconds: 1));
          final state = container.read(velockWizardSessionProvider);
          expect(
            state.authorizationProblem,
            VelockWizardAuthorizationProblem.expired,
          );
          expect(state.session, isNull);
          expect(state.approval, isNull);
          expect(async.pendingTimers, isEmpty);

          container.dispose();
        });
      },
    );

    test(
      'reset cancels the expiry timer without a late state change',
      () async {
        final session = fixture.session(requestId: 'reset-request');
        final approval = await fixture.approvalFor(session);

        fakeAsync((async) {
          final container = _controllerContainer(
            clock: () => fixture.base.add(async.elapsed),
          );
          final controller = container.read(
            velockWizardSessionProvider.notifier,
          );

          controller.sessionStarted(session);
          controller.approved(approval);
          expect(async.pendingTimers, hasLength(1));

          controller.reset();
          expect(async.pendingTimers, isEmpty);
          async.elapse(const Duration(minutes: 10));

          final state = container.read(velockWizardSessionProvider);
          expect(state.session, isNull);
          expect(state.approval, isNull);
          expect(state.authorizationProblem, isNull);
          container.dispose();
        });
      },
    );

    test('finalization cancels the expiry timer', () async {
      final session = fixture.session(requestId: 'finalized-request');
      final approval = await fixture.approvalFor(session);

      fakeAsync((async) {
        final container = _controllerContainer(
          clock: () => fixture.base.add(async.elapsed),
        );
        final controller = container.read(velockWizardSessionProvider.notifier);

        controller.sessionStarted(session);
        controller.approved(approval);
        expect(async.pendingTimers, hasLength(1));

        controller.profileFinalized(fixture.finalizationResult(session));
        expect(async.pendingTimers, isEmpty);
        container.dispose();
      });
    });

    test(
      'clearCompletedFlow keeps a pending acknowledgement session',
      () async {
        final session = fixture.session(requestId: 'pending-ack-request');
        final approval = await fixture.approvalFor(session);
        final result = fixture.finalizationResult(session);
        expect(result.pairingAcknowledged, isFalse);

        fakeAsync((async) {
          final container = _controllerContainer(
            clock: () => fixture.base.add(async.elapsed),
          );
          final controller = container.read(
            velockWizardSessionProvider.notifier,
          );

          controller.sessionStarted(session);
          controller.approved(approval);
          expect(async.pendingTimers, hasLength(1));
          expect(
            controller.profileFinalized(
              result,
              session: session,
              approval: approval,
            ),
            isTrue,
          );
          expect(async.pendingTimers, isEmpty);

          controller.clearCompletedFlow();

          final state = container.read(velockWizardSessionProvider);
          expect(state.session, same(session));
          expect(state.approval, same(approval));
          expect(state.finalization, same(result));
          expect(async.pendingTimers, isEmpty);
          container.dispose();
        });
      },
    );

    test(
      'late finalization from an old session cannot replace the new flow',
      () async {
        final oldSession = fixture.session(requestId: 'late-old-request');
        final oldApproval = await fixture.approvalFor(oldSession);
        final oldResult = fixture.finalizationResult(
          oldSession,
          pairingAcknowledged: true,
        );
        final newSession = fixture.session(requestId: 'new-current-request');
        final newApproval = await fixture.approvalFor(newSession);

        fakeAsync((async) {
          final container = _controllerContainer(
            clock: () => fixture.base.add(async.elapsed),
          );
          final controller = container.read(
            velockWizardSessionProvider.notifier,
          );

          controller.sessionStarted(oldSession);
          controller.approved(oldApproval);
          controller.sessionStarted(newSession);
          controller.approved(newApproval);

          expect(
            controller.profileFinalized(
              oldResult,
              session: oldSession,
              approval: oldApproval,
            ),
            isFalse,
          );

          final state = container.read(velockWizardSessionProvider);
          expect(state.session, same(newSession));
          expect(state.approval, same(newApproval));
          expect(state.finalization, isNull);
          expect(state.authorizationProblem, isNull);
          expect(async.pendingTimers, hasLength(1));
          container.dispose();
        });
      },
    );

    test('container disposal cancels the expiry timer', () async {
      final session = fixture.session(requestId: 'dispose-request');
      final approval = await fixture.approvalFor(session);

      fakeAsync((async) {
        final container = _controllerContainer(
          clock: () => fixture.base.add(async.elapsed),
        );
        final controller = container.read(velockWizardSessionProvider.notifier);

        controller.sessionStarted(session);
        controller.approved(approval);
        expect(async.pendingTimers, hasLength(1));

        container.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('VelockDatasetWizard pairing recovery', () {
    late _WidgetHarness harness;

    setUp(() async {
      harness = await _WidgetHarness.create();
    });

    tearDown(() {
      harness.dispose();
    });

    testWidgets(
      'an approved request expires into renewal without showing success',
      (tester) async {
        try {
          final session = await harness.seedApproved(
            requestId: 'approved-expiry-request',
          );
          await _pumpWizard(tester, harness);

          expect(find.textContaining('格间已允许连接'), findsOneWidget);
          expect(
            find.byKey(const Key('continue-velock-setup')),
            findsOneWidget,
          );

          harness.clock.value = session.request.expiresAt;
          await tester.pump(const Duration(minutes: 5));
          await tester.pump();

          final state = harness.state;
          expect(
            state.authorizationProblem,
            VelockWizardAuthorizationProblem.expired,
          );
          expect(state.session, isNull);
          expect(state.approval, isNull);
          expect(find.textContaining('连接授权已过期'), findsOneWidget);
          expect(
            find.byKey(const Key('renew-velock-authorization')),
            findsOneWidget,
          );
          expect(find.textContaining('格间已允许连接'), findsNothing);
          expect(find.byKey(const Key('continue-velock-setup')), findsNothing);
          expect(find.byKey(const Key('go-create-connection')), findsNothing);
        } finally {
          harness.controller.reset();
        }
      },
    );

    testWidgets(
      'renew creates a new request and preserves restoring selection',
      (tester) async {
        try {
          harness.connections
            ..clear()
            ..add(_connection('connection-restore'));
          await harness.seedInvalid(
            requestId: 'old-request',
            reason: VelockWizardAuthorizationProblem.expired,
            selectedConnectionId: 'connection-restore',
            connectionNeeded: true,
          );
          await _pumpWizard(tester, harness, restoring: true);

          expect(
            find.byKey(const Key('renew-velock-authorization')),
            findsOneWidget,
          );
          await tester.ensureVisible(
            find.byKey(const Key('renew-velock-authorization')),
          );
          await tester.tap(find.byKey(const Key('renew-velock-authorization')));
          await tester.pumpAndSettle();

          final freshSession = harness.state.session;
          expect(freshSession, isNotNull);
          expect(freshSession!.request.requestId, isNot('old-request'));
          expect(harness.control.submitted, hasLength(1));
          expect(
            harness.control.launches.single.queryParameters['requestId'],
            freshSession.request.requestId,
          );
          expect(harness.state.selectedConnectionId, 'connection-restore');
          expect(harness.readiness.inspectCount, 1);

          await harness.control.approve(freshSession);
          final inspectButton = find.byKey(
            const Key('inspect-velock-readiness'),
          );
          await tester.ensureVisible(inspectButton);
          await tester.tap(inspectButton);
          await tester.pumpAndSettle();

          expect(
            harness.state.approval?.requestId,
            freshSession.request.requestId,
          );
          expect(harness.state.selectedConnectionId, 'connection-restore');
          expect(find.text('确认恢复位置'), findsOneWidget);
          expect(
            tester
                .widget<VelockDatasetWizard>(find.byType(VelockDatasetWizard))
                .restoring,
            isTrue,
          );
        } finally {
          harness.controller.reset();
        }
      },
    );

    testWidgets(
      'a tampered approval is invalidated before cloud or finalizer access',
      (tester) async {
        try {
          final session = harness.fixture.session(
            requestId: 'tampered-request',
          );
          await harness.control.approve(
            session,
            challenge: 'wrong-challenge',
            tamperAfterSign: true,
          );
          harness.controller.sessionStarted(session);

          await _pumpWizard(tester, harness);

          final state = harness.state;
          expect(
            state.authorizationProblem,
            VelockWizardAuthorizationProblem.invalid,
          );
          expect(state.session, isNull);
          expect(state.approval, isNull);
          expect(find.textContaining('需要重新授权'), findsOneWidget);
          expect(
            find.byKey(const Key('renew-velock-authorization')),
            findsOneWidget,
          );
          expect(find.textContaining('格间已允许连接'), findsNothing);
          expect(find.byKey(const Key('continue-velock-setup')), findsNothing);
          expect(harness.destination.checkCount, 0);
          expect(harness.finalizer.finalizeCount, 0);
        } finally {
          harness.controller.reset();
        }
      },
    );

    testWidgets(
      'a finalizer invalid pairing response enters renewal recovery',
      (tester) async {
        try {
          harness.connections
            ..clear()
            ..add(_connection('connection-restore'));
          await harness.seedApproved(
            requestId: 'finalizer-request',
            selectedConnectionId: 'connection-restore',
          );
          harness.finalizer.invalidOnFinalize = true;

          await _pumpWizard(tester, harness, restoring: true);
          final continueButton = find.byKey(const Key('continue-velock-setup'));
          await tester.ensureVisible(continueButton);
          await tester.tap(continueButton);
          await tester.pumpAndSettle();

          expect(find.text('确认恢复位置'), findsOneWidget);
          await tester.tap(find.byKey(const Key('finalize-velock-profile')));
          await tester.pumpAndSettle();

          expect(harness.destination.checkCount, 1);
          expect(harness.finalizer.finalizeCount, 1);
          expect(
            harness.state.authorizationProblem,
            VelockWizardAuthorizationProblem.invalid,
          );
          expect(find.textContaining('需要重新授权'), findsOneWidget);
          expect(
            find.byKey(const Key('renew-velock-authorization')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('finalize-velock-profile')),
            findsNothing,
          );
        } finally {
          harness.controller.reset();
        }
      },
    );
    testWidgets(
      'review confirmation after authorization expiry does not touch cloud or finalizer',
      (tester) async {
        try {
          harness.connections
            ..clear()
            ..add(_connection('connection-restore'));
          final session = await harness.seedApproved(
            requestId: 'review-expiry-request',
            selectedConnectionId: 'connection-restore',
          );
          await _pumpWizard(tester, harness, restoring: true);

          final continueButton = find.byKey(const Key('continue-velock-setup'));
          await tester.ensureVisible(continueButton);
          await tester.tap(continueButton);
          await tester.pumpAndSettle();
          expect(find.text('确认恢复位置'), findsOneWidget);

          harness.clock.value = session.request.expiresAt;
          await tester.pump(const Duration(minutes: 5));
          await tester.pump();

          await tester.tap(find.byKey(const Key('finalize-velock-profile')));
          await tester.pumpAndSettle();

          expect(harness.destination.checkCount, 0);
          expect(harness.finalizer.finalizeCount, 0);
          expect(find.textContaining('连接授权已过期'), findsOneWidget);
          expect(
            find.byKey(const Key('renew-velock-authorization')),
            findsOneWidget,
          );
        } finally {
          harness.controller.reset();
        }
      },
    );

    testWidgets(
      'existing profiles do not hide a pending acknowledgement card',
      (tester) async {
        try {
          harness.existingProfiles.add(
            const SyncProfileSummary(
              profileId: 'existing-profile',
              state: SyncProfileState.active,
              backgroundPolicy: SyncProfileBackgroundPolicy(),
              displayName: 'Existing profile',
            ),
          );
          final session = await harness.seedApproved(
            requestId: 'existing-profile-ack-request',
          );
          final approval = harness.state.approval!;
          expect(
            harness.controller.profileFinalized(
              harness.fixture.finalizationResult(session),
              session: session,
              approval: approval,
            ),
            isTrue,
          );

          await _pumpWizard(tester, harness);

          expect(
            find.byKey(const Key('retry-velock-acknowledgement')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('velock-already-paired')), findsNothing);
        } finally {
          harness.controller.reset();
        }
      },
    );
  });
}

ProviderContainer _controllerContainer({required DateTime Function() clock}) =>
    ProviderContainer(
      overrides: [velockWizardClockProvider.overrideWithValue(clock)],
    );

Future<void> _pumpWizard(
  WidgetTester tester,
  _WidgetHarness harness, {
  bool restoring = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: PlatformProvider(
        initialPlatform: TargetPlatform.iOS,
        builder: (_) => MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: VelockDatasetWizard(restoring: restoring),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _SignedFixture {
  _SignedFixture({
    required this.base,
    required this.signingKey,
    required this.descriptor,
  });

  final DateTime base;
  final SimpleKeyPair signingKey;
  final VelockPairingDescriptor descriptor;

  static Future<_SignedFixture> create({DateTime? base}) async {
    final effectiveBase = (base ?? DateTime.now().toUtc()).toUtc();
    final signingKey = await Ed25519().newKeyPairFromSeed(
      List<int>.filled(32, 17),
    );
    final publicKey = base64UrlEncode(
      (await signingKey.extractPublicKey()).bytes,
    );
    return _SignedFixture(
      base: effectiveBase,
      signingKey: signingKey,
      descriptor: _descriptor(publicKey, effectiveBase),
    );
  }

  VelockPairingSession session({
    required String requestId,
    String? challenge,
    Duration ttl = const Duration(minutes: 5),
  }) => VelockPairingSession(
    descriptor: descriptor,
    request: VelockPairingControlRequest(
      requestId: requestId,
      challenge: challenge ?? '$requestId-challenge',
      producerId: descriptor.producerId,
      producerPublicKeyId: descriptor.producerPublicKeyId,
      exchangeBindingId: descriptor.exchangeBindingId,
      syncAppInstanceId: 'sync-instance-1',
      createdAt: base,
      expiresAt: base.add(ttl),
    ),
  );

  Future<VelockPairingControlResponse> approvalFor(
    VelockPairingSession session, {
    String? requestId,
    String? challenge,
    DateTime? approvedAt,
    DateTime? expiresAt,
    bool tamperAfterSign = false,
  }) => _signedApproval(
    session: session,
    signingKey: signingKey,
    requestId: requestId,
    challenge: challenge,
    approvedAt: approvedAt,
    expiresAt: expiresAt,
    tamperAfterSign: tamperAfterSign,
  );

  VelockProfileFinalizationResult finalizationResult(
    VelockPairingSession session, {
    bool pairingAcknowledged = false,
  }) => VelockProfileFinalizationResult(
    profile: VelockSyncProfile(
      profileId: 'profile-1',
      datasetId: 'vault-1',
      vaultId: 'vault-1',
      deviceId: session.request.syncAppInstanceId,
      displayName: 'Personal vault',
      connectionId: 'connection-1',
      pairedProducerId: session.descriptor.producerId,
      pairedProducerPublicKeyId: session.descriptor.producerPublicKeyId,
      exchangeBindingId: session.descriptor.exchangeBindingId,
      backgroundPolicy: const SyncProfileBackgroundPolicy(),
      state: SyncProfileState.active,
      createdAt: base,
    ),
    pairingAcknowledged: pairingAcknowledged,
  );
}

class _WidgetHarness {
  _WidgetHarness({
    required this.fixture,
    required this.clock,
    required this.container,
    required this.control,
    required this.pairing,
    required this.readiness,
    required this.finalizer,
    required this.destination,
    required this.connections,
    required this.existingProfiles,
  });

  final _SignedFixture fixture;
  final _MutableClock clock;
  final ProviderContainer container;
  final _RecordingControl control;
  final PlatformVelockPairingSessionService pairing;
  final _RecordingReadiness readiness;
  final _RecordingFinalizer finalizer;
  final _RecordingDestination destination;
  final List<ConnectionModel> connections;
  final List<SyncProfileSummary> existingProfiles;

  static Future<_WidgetHarness> create() async {
    final fixture = await _SignedFixture.create();
    final clock = _MutableClock(fixture.base);
    final control = _RecordingControl(
      descriptor: fixture.descriptor,
      signingKey: fixture.signingKey,
    );
    var nextId = 0;
    final pairing = PlatformVelockPairingSessionService(
      control: control,
      now: clock.call,
      nextId: () => 'generated-${++nextId}',
      launchVelock: (uri) async {
        control.launches.add(uri);
        return true;
      },
    );
    final readiness = _RecordingReadiness(fixture.descriptor);
    final finalizer = _RecordingFinalizer();
    final destination = _RecordingDestination();
    final connections = <ConnectionModel>[
      _connection('connection-a'),
      _connection('connection-restore'),
    ];
    final existingProfiles = <SyncProfileSummary>[];
    final container = ProviderContainer(
      overrides: [
        velockWizardClockProvider.overrideWithValue(clock.call),
        velockExistingProfilesProvider.overrideWith(
          (ref) async => existingProfiles,
        ),
        velockWizardConnectionsProvider.overrideWithValue(
          () async => connections,
        ),
        velockSyncAppInstanceIdProvider.overrideWithValue(
          () async => 'sync-instance-1',
        ),
        velockPairingSessionServiceProvider.overrideWithValue(pairing),
        velockWizardReadinessServiceProvider.overrideWithValue(readiness),
        velockProfileFinalizerProvider.overrideWithValue(finalizer),
        backupDestinationServiceProvider.overrideWithValue(destination),
        syncSettingsServiceProvider.overrideWithValue(_TestSettings()),
      ],
    );
    return _WidgetHarness(
      fixture: fixture,
      clock: clock,
      container: container,
      control: control,
      pairing: pairing,
      readiness: readiness,
      finalizer: finalizer,
      destination: destination,
      connections: connections,
      existingProfiles: existingProfiles,
    );
  }

  VelockWizardSessionController get controller =>
      container.read(velockWizardSessionProvider.notifier);

  VelockWizardSessionState get state =>
      container.read(velockWizardSessionProvider);

  Future<VelockPairingSession> seedApproved({
    required String requestId,
    String? selectedConnectionId,
  }) async {
    final session = fixture.session(requestId: requestId);
    await control.approve(session);
    final inspection = await pairing.inspect(session);
    expect(inspection.isApproved, isTrue);
    controller.sessionStarted(session);
    controller.approved(inspection.response!);
    if (selectedConnectionId != null) {
      controller.connectionSelected(selectedConnectionId);
    }
    return session;
  }

  Future<VelockPairingSession> seedInvalid({
    required String requestId,
    required VelockWizardAuthorizationProblem reason,
    String? selectedConnectionId,
    bool connectionNeeded = false,
  }) async {
    final session = fixture.session(requestId: requestId);
    final approval = await fixture.approvalFor(session);
    controller.sessionStarted(session);
    controller.approved(approval);
    if (selectedConnectionId != null) {
      controller.connectionSelected(selectedConnectionId);
    }
    if (connectionNeeded) {
      controller.connectionMissing();
    }
    controller.authorizationInvalidated(session, reason);
    return session;
  }

  void dispose() => container.dispose();
}

class _MutableClock {
  _MutableClock(this.value);

  DateTime value;

  DateTime call() => value;
}

class _RecordingReadiness implements VelockWizardReadinessService {
  _RecordingReadiness(this.descriptor);

  final VelockPairingDescriptor descriptor;
  int inspectCount = 0;

  @override
  Future<VelockWizardReadiness> inspect({String? syncAppInstanceId}) async {
    inspectCount += 1;
    return VelockWizardReadiness(
      VelockWizardAvailability.ready,
      descriptor: descriptor,
    );
  }
}

class _RecordingControl implements VelockPairingControlChannel {
  _RecordingControl({required this.descriptor, required this.signingKey});

  final VelockPairingDescriptor descriptor;
  final SimpleKeyPair signingKey;
  final List<VelockPairingControlRequest> submitted =
      <VelockPairingControlRequest>[];
  final Map<String, VelockPairingControlResponse> responses =
      <String, VelockPairingControlResponse>{};
  final List<Uri> launches = <Uri>[];
  int queryCount = 0;
  String? acknowledgedRequestId;

  @override
  Future<VelockPairingDescriptor> pairingDescriptor() async => descriptor;

  @override
  Future<VelockDeviceAuthorizationStatus> queryAuthorizationStatus(
    String syncAppInstanceId,
  ) async => VelockDeviceAuthorizationStatus.granted;

  @override
  Future<VelockPairingControlStatus> submitPairingRequest(
    VelockPairingControlRequest request,
  ) async {
    submitted.add(request);
    return VelockPairingControlStatus.pending;
  }

  @override
  Future<VelockPairingControlResult> queryPairingResponse(
    String requestId,
  ) async {
    queryCount += 1;
    final response = responses[requestId];
    return response == null
        ? const VelockPairingControlResult(
            status: VelockPairingControlStatus.pending,
          )
        : VelockPairingControlResult(
            status: VelockPairingControlStatus.approved,
            response: response,
          );
  }

  @override
  Future<void> acknowledgePairing(String requestId) async {
    acknowledgedRequestId = requestId;
  }

  Future<void> approve(
    VelockPairingSession session, {
    String? requestId,
    String? challenge,
    bool tamperAfterSign = false,
  }) async {
    responses[session.request.requestId] = await _signedApproval(
      session: session,
      signingKey: signingKey,
      requestId: requestId,
      challenge: challenge,
      tamperAfterSign: tamperAfterSign,
    );
  }
}

class _RecordingFinalizer implements VelockProfileFinalizer {
  int finalizeCount = 0;
  int retryAcknowledgementCount = 0;
  bool invalidOnFinalize = false;

  @override
  Future<VelockProfileFinalizationResult> finalize({
    required VelockPairingSession session,
    required VelockPairingControlResponse approval,
    required String connectionId,
    required String displayName,
    required SyncProfileBackgroundPolicy backgroundPolicy,
    required bool userConfirmed,
  }) async {
    finalizeCount += 1;
    if (invalidOnFinalize) {
      throw const VelockProfileFinalizationException(
        'invalid_pairing_response',
      );
    }
    throw StateError('Unexpected finalize call in this recovery test.');
  }

  @override
  Future<bool> retryAcknowledgement(VelockPairingSession session) async {
    retryAcknowledgementCount += 1;
    return false;
  }
}

class _RecordingDestination extends BackupDestinationService {
  _RecordingDestination()
    : super(
        open: (_) async =>
            throw StateError('Destination open is not expected.'),
      );

  int checkCount = 0;

  @override
  Future<void> check({
    required String connectionId,
    required String vaultId,
    required Iterable<String> trustedProducerIds,
    required bool restoring,
  }) async {
    checkCount += 1;
  }
}

class _TestSettings implements SyncSettingsService {
  @override
  Future<SyncSettingsSnapshot> load() async => const SyncSettingsSnapshot(
    settings: SyncGlobalSettings(),
    backgroundSupported: false,
    backgroundEligibleProfileCount: 0,
    staging: StagingSpaceSummary(),
    garbageCollection: null,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

VelockPairingDescriptor _descriptor(String publicKey, DateTime now) =>
    VelockPairingDescriptor.parse(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'controlVersion': 1,
            'exchangeBindingId': 'binding-1',
            'exchangeVersion': 1,
            'producerId': 'producer-1',
            'producerPublicKeyId': 'key-1',
            'producerSigningPublicKey': publicKey,
            'protocol': 'velock-sync',
            'protocolVersion': 1,
            'publishedAt': now.toIso8601String(),
            'signatureAlgorithm': 'Ed25519',
          }),
        ),
      ),
    );

ConnectionModel _connection(String id) => ConnectionModel(
  id: id,
  name: id == 'connection-restore' ? '恢复位置' : '云端位置',
  source: '格间',
  target: '云端',
  protocol: const ProtocolModel.webDav(
    protocolType: WebDavProtocolType.https,
    address: 'https://example.test',
    port: '443',
    path: '/velock',
  ),
  createdAt: DateTime.utc(2026, 9, 26),
  updatedAt: DateTime.utc(2026, 9, 26),
  status: ConnectionStatus.active,
);

Future<VelockPairingControlResponse> _signedApproval({
  required VelockPairingSession session,
  required SimpleKeyPair signingKey,
  String? requestId,
  String? challenge,
  DateTime? approvedAt,
  DateTime? expiresAt,
  bool tamperAfterSign = false,
}) async {
  final effectiveApprovedAt =
      (approvedAt ?? session.request.createdAt.add(const Duration(seconds: 5)))
          .toUtc();
  final effectiveExpiresAt = (expiresAt ?? session.request.expiresAt).toUtc();
  final unsigned = <String, Object>{
    'approvedAt': effectiveApprovedAt.toIso8601String(),
    'challenge': challenge ?? session.request.challenge,
    'deviceDisplayName': 'Test device',
    'exchangeBindingId': session.request.exchangeBindingId,
    'expiresAt': effectiveExpiresAt.toIso8601String(),
    'producerId': session.request.producerId,
    'producerPublicKeyId': session.request.producerPublicKeyId,
    'producerSigningPublicKey': session.descriptor.producerSigningPublicKey,
    'requestId': requestId ?? session.request.requestId,
    'vaultDisplayName': 'Personal vault',
    'vaultId': 'vault-1',
  };
  final signature = await Ed25519().sign(
    Uint8List.fromList(utf8.encode(jsonEncode(unsigned))),
    keyPair: signingKey,
  );
  final encoded = <String, Object>{
    ...unsigned,
    'signature': base64UrlEncode(signature.bytes),
  };
  if (tamperAfterSign) {
    encoded['vaultDisplayName'] = 'Tampered vault';
  }
  return VelockPairingControlResponse.parse(
    Uint8List.fromList(utf8.encode(jsonEncode(encoded))),
  );
}
