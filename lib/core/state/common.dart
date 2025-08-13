import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/features/dashboard/repository/dashboard_repository.dart';

part '../../generated/core/state/common.g.dart';

@riverpod
LocalDataManager localDataManager(Ref ref) {
  return LocalDataManager.instance;
}

@riverpod
AppSetting appSetting(Ref ref) {
  final manager = ref.watch(localDataManagerProvider);
  return AppSetting(manager);
}

@riverpod
DashboardRepository dashboardRepository(Ref ref) {
  final manager = ref.watch(localDataManagerProvider);
  return DashboardRepository(manager);
}


@riverpod
ConnectionRepository connectionRepository(Ref ref) {
  final manager = ref.watch(localDataManagerProvider);
  return ConnectionRepository(manager);
}