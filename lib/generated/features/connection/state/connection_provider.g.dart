// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../../../features/connection/state/connection_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(Connections)
const connectionsProvider = ConnectionsProvider._();

final class ConnectionsProvider
    extends $AsyncNotifierProvider<Connections, List<ConnectionModel>> {
  const ConnectionsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'connectionsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$connectionsHash();

  @$internal
  @override
  Connections create() => Connections();
}

String _$connectionsHash() => r'8f7ea7947830a66ad035747441f8fe63523436b9';

abstract class _$Connections extends $AsyncNotifier<List<ConnectionModel>> {
  FutureOr<List<ConnectionModel>> build();
  @$mustCallSuper
  @override
  void runBuild() {
    final created = build();
    final ref =
        this.ref
            as $Ref<AsyncValue<List<ConnectionModel>>, List<ConnectionModel>>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<
                AsyncValue<List<ConnectionModel>>,
                List<ConnectionModel>
              >,
              AsyncValue<List<ConnectionModel>>,
              Object?,
              Object?
            >;
    element.handleValue(ref, created);
  }
}

@ProviderFor(ConnectionCreation)
const connectionCreationProvider = ConnectionCreationProvider._();

final class ConnectionCreationProvider
    extends $NotifierProvider<ConnectionCreation, CreateConnectionDto?> {
  const ConnectionCreationProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'connectionCreationProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$connectionCreationHash();

  @$internal
  @override
  ConnectionCreation create() => ConnectionCreation();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(CreateConnectionDto? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<CreateConnectionDto?>(value),
    );
  }
}

String _$connectionCreationHash() =>
    r'2246a88dfb297fff1bfc1cdb529395f5a1e79c88';

abstract class _$ConnectionCreation extends $Notifier<CreateConnectionDto?> {
  CreateConnectionDto? build();
  @$mustCallSuper
  @override
  void runBuild() {
    final created = build();
    final ref = this.ref as $Ref<CreateConnectionDto?, CreateConnectionDto?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<CreateConnectionDto?, CreateConnectionDto?>,
              CreateConnectionDto?,
              Object?,
              Object?
            >;
    element.handleValue(ref, created);
  }
}

@ProviderFor(ConnectionDetail)
const connectionDetailProvider = ConnectionDetailFamily._();

final class ConnectionDetailProvider
    extends $AsyncNotifierProvider<ConnectionDetail, ConnectionModel?> {
  const ConnectionDetailProvider._({
    required ConnectionDetailFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'connectionDetailProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$connectionDetailHash();

  @override
  String toString() {
    return r'connectionDetailProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  ConnectionDetail create() => ConnectionDetail();

  @override
  bool operator ==(Object other) {
    return other is ConnectionDetailProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$connectionDetailHash() => r'cc0d37438226b4f7f72517a031fbb58d8cf0af8d';

final class ConnectionDetailFamily extends $Family
    with
        $ClassFamilyOverride<
          ConnectionDetail,
          AsyncValue<ConnectionModel?>,
          ConnectionModel?,
          FutureOr<ConnectionModel?>,
          String
        > {
  const ConnectionDetailFamily._()
    : super(
        retry: null,
        name: r'connectionDetailProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ConnectionDetailProvider call(String id) =>
      ConnectionDetailProvider._(argument: id, from: this);

  @override
  String toString() => r'connectionDetailProvider';
}

abstract class _$ConnectionDetail extends $AsyncNotifier<ConnectionModel?> {
  late final _$args = ref.$arg as String;
  String get id => _$args;

  FutureOr<ConnectionModel?> build(String id);
  @$mustCallSuper
  @override
  void runBuild() {
    final created = build(_$args);
    final ref =
        this.ref as $Ref<AsyncValue<ConnectionModel?>, ConnectionModel?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<ConnectionModel?>, ConnectionModel?>,
              AsyncValue<ConnectionModel?>,
              Object?,
              Object?
            >;
    element.handleValue(ref, created);
  }
}
