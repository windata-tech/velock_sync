// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../../../features/dashboard/state/dashboard_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(SyncTasks)
const syncTasksProvider = SyncTasksProvider._();

final class SyncTasksProvider
    extends $AsyncNotifierProvider<SyncTasks, List<SyncTask>> {
  const SyncTasksProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'syncTasksProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$syncTasksHash();

  @$internal
  @override
  SyncTasks create() => SyncTasks();
}

String _$syncTasksHash() => r'3d59e624c1c0f4c98d8036822cf97eb66ca0905f';

abstract class _$SyncTasks extends $AsyncNotifier<List<SyncTask>> {
  FutureOr<List<SyncTask>> build();
  @$mustCallSuper
  @override
  void runBuild() {
    final created = build();
    final ref = this.ref as $Ref<AsyncValue<List<SyncTask>>, List<SyncTask>>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<List<SyncTask>>, List<SyncTask>>,
              AsyncValue<List<SyncTask>>,
              Object?,
              Object?
            >;
    element.handleValue(ref, created);
  }
}
