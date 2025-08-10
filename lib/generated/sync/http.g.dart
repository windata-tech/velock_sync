// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../sync/http.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

@ProviderFor(dio)
const dioProvider = DioProvider._();

final class DioProvider extends $FunctionalProvider<Dio, Dio, Dio>
    with $Provider<Dio> {
  const DioProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'dioProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$dioHash();

  @$internal
  @override
  $ProviderElement<Dio> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  Dio create(Ref ref) {
    return dio(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(Dio value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<Dio>(value),
    );
  }
}

String _$dioHash() => r'752e988f9490880f64bef088652cc7723ff31e0b';

@ProviderFor(webDavRepository)
const webDavRepositoryProvider = WebDavRepositoryProvider._();

final class WebDavRepositoryProvider
    extends
        $FunctionalProvider<
          WebDavRepository,
          WebDavRepository,
          WebDavRepository
        >
    with $Provider<WebDavRepository> {
  const WebDavRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'webDavRepositoryProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$webDavRepositoryHash();

  @$internal
  @override
  $ProviderElement<WebDavRepository> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  WebDavRepository create(Ref ref) {
    return webDavRepository(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(WebDavRepository value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<WebDavRepository>(value),
    );
  }
}

String _$webDavRepositoryHash() => r'a93af0f7b8a5fc4987aaa4bdec453d0f7455ff17';

// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
