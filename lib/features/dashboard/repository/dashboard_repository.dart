import 'dart:convert';

import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/domain/sync_task.dart';

class DashboardRepository {
  DashboardRepository(this._localDataManager);

  final LocalDataManager _localDataManager;

  List<SyncTask>? get syncTasks {
    final json = _localDataManager.getStringList(AppKeys.syncTask);
    if (json == null) return null;
    return json.map((e) => SyncTask.fromJson(jsonDecode(e))).toList();
  }

  Future<void> setSyncTasks(List<SyncTask> value) {
    final json = value.map((e) => jsonEncode(e.toJson())).toList();
    return _localDataManager.setStringList(AppKeys.syncTask, json);
  }
}
