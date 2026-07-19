// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../../core/state/download.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(DownloadManager)
const downloadManagerProvider = DownloadManagerProvider._();

final class DownloadManagerProvider
    extends $AsyncNotifierProvider<DownloadManager, List<DownloadTask>> {
  const DownloadManagerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'downloadManagerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$downloadManagerHash();

  @$internal
  @override
  DownloadManager create() => DownloadManager();
}

String _$downloadManagerHash() => r'9ee823745dc32fbb4b36ae88882f5ea7471b5074';

abstract class _$DownloadManager extends $AsyncNotifier<List<DownloadTask>> {
  FutureOr<List<DownloadTask>> build();
  @$mustCallSuper
  @override
  void runBuild() {
    final created = build();
    final ref =
        this.ref as $Ref<AsyncValue<List<DownloadTask>>, List<DownloadTask>>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<List<DownloadTask>>, List<DownloadTask>>,
              AsyncValue<List<DownloadTask>>,
              Object?,
              Object?
            >;
    element.handleValue(ref, created);
  }
}
