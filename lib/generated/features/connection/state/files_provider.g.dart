// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../../../features/connection/state/files_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(RemoteFileBrowser)
const remoteFileBrowserProvider = RemoteFileBrowserFamily._();

final class RemoteFileBrowserProvider
    extends $AsyncNotifierProvider<RemoteFileBrowser, FileBrowserState> {
  const RemoteFileBrowserProvider._({
    required RemoteFileBrowserFamily super.from,
    required ConnectionModel super.argument,
  }) : super(
         retry: null,
         name: r'remoteFileBrowserProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$remoteFileBrowserHash();

  @override
  String toString() {
    return r'remoteFileBrowserProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  RemoteFileBrowser create() => RemoteFileBrowser();

  @override
  bool operator ==(Object other) {
    return other is RemoteFileBrowserProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$remoteFileBrowserHash() => r'60fd8969e5fd2c43014f80f0ddd56a8e740cfb90';

final class RemoteFileBrowserFamily extends $Family
    with
        $ClassFamilyOverride<
          RemoteFileBrowser,
          AsyncValue<FileBrowserState>,
          FileBrowserState,
          FutureOr<FileBrowserState>,
          ConnectionModel
        > {
  const RemoteFileBrowserFamily._()
    : super(
        retry: null,
        name: r'remoteFileBrowserProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  RemoteFileBrowserProvider call({required ConnectionModel connectionModel}) =>
      RemoteFileBrowserProvider._(argument: connectionModel, from: this);

  @override
  String toString() => r'remoteFileBrowserProvider';
}

abstract class _$RemoteFileBrowser extends $AsyncNotifier<FileBrowserState> {
  late final _$args = ref.$arg as ConnectionModel;
  ConnectionModel get connectionModel => _$args;

  FutureOr<FileBrowserState> build({required ConnectionModel connectionModel});
  @$mustCallSuper
  @override
  void runBuild() {
    final created = build(connectionModel: _$args);
    final ref =
        this.ref as $Ref<AsyncValue<FileBrowserState>, FileBrowserState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<FileBrowserState>, FileBrowserState>,
              AsyncValue<FileBrowserState>,
              Object?,
              Object?
            >;
    element.handleValue(ref, created);
  }
}
