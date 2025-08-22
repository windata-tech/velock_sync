// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../../core/state/common.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

@ProviderFor(localDataManager)
const localDataManagerProvider = LocalDataManagerProvider._();

final class LocalDataManagerProvider
    extends
        $FunctionalProvider<
          LocalDataManager,
          LocalDataManager,
          LocalDataManager
        >
    with $Provider<LocalDataManager> {
  const LocalDataManagerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'localDataManagerProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$localDataManagerHash();

  @$internal
  @override
  $ProviderElement<LocalDataManager> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  LocalDataManager create(Ref ref) {
    return localDataManager(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LocalDataManager value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LocalDataManager>(value),
    );
  }
}

String _$localDataManagerHash() => r'2c81463f5c794b518cde0bb587294b6298b5d89a';

@ProviderFor(appSetting)
const appSettingProvider = AppSettingProvider._();

final class AppSettingProvider
    extends $FunctionalProvider<AppSetting, AppSetting, AppSetting>
    with $Provider<AppSetting> {
  const AppSettingProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'appSettingProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$appSettingHash();

  @$internal
  @override
  $ProviderElement<AppSetting> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  AppSetting create(Ref ref) {
    return appSetting(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AppSetting value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AppSetting>(value),
    );
  }
}

String _$appSettingHash() => r'6b35334820f2a33ab3c81fecad7e9c240fcae20c';

@ProviderFor(dashboardRepository)
const dashboardRepositoryProvider = DashboardRepositoryProvider._();

final class DashboardRepositoryProvider
    extends
        $FunctionalProvider<
          DashboardRepository,
          DashboardRepository,
          DashboardRepository
        >
    with $Provider<DashboardRepository> {
  const DashboardRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'dashboardRepositoryProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$dashboardRepositoryHash();

  @$internal
  @override
  $ProviderElement<DashboardRepository> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  DashboardRepository create(Ref ref) {
    return dashboardRepository(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(DashboardRepository value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<DashboardRepository>(value),
    );
  }
}

String _$dashboardRepositoryHash() =>
    r'eb630f6bb5c4363ac5072311a791ed7015633aeb';

@ProviderFor(connectionRepository)
const connectionRepositoryProvider = ConnectionRepositoryProvider._();

final class ConnectionRepositoryProvider
    extends
        $FunctionalProvider<
          ConnectionRepository,
          ConnectionRepository,
          ConnectionRepository
        >
    with $Provider<ConnectionRepository> {
  const ConnectionRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'connectionRepositoryProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$connectionRepositoryHash();

  @$internal
  @override
  $ProviderElement<ConnectionRepository> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  ConnectionRepository create(Ref ref) {
    return connectionRepository(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ConnectionRepository value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ConnectionRepository>(value),
    );
  }
}

String _$connectionRepositoryHash() =>
    r'c24bd89bb2f3a4e68f7405f74426a2fa71e15294';

// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
