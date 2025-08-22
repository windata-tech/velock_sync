// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../../../features/connection/state/connection_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

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

String _$connectionsHash() => r'8c7e19a98b625dcb04939322b2fb10b708097741';

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

// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
