import 'package:velock_sync/core/local_data_manager.dart';

abstract class AppKeys {
  static const String themeMode = 'app_theme_mode';
  static const String notificationEnabled = 'app_notification_enabled';
  static const String languageCode = 'app_language_code';
  static const String isShowPinnedOfDashboardPage = 'is_show_pinned_of_dashboard_page';
  static const String syncTask = 'sync_task';
}

class AppSetting {
  AppSetting(this._localDataManager);

  final LocalDataManager _localDataManager;

  String? get languageCode {
    return _localDataManager.getString(AppKeys.languageCode);
  }

  Future<void> setLanguageCode(String value) {
    return _localDataManager.setString(AppKeys.languageCode, value);
  }

  Future<bool?> get isShowPinnedOfDashboardPage {
    return _localDataManager.getBoolAsync(AppKeys.isShowPinnedOfDashboardPage, defaultValue: true);
  }

  Future<void> setShowPinnedOfDashboardPage(bool value) {
    return _localDataManager.setBoolAsync(AppKeys.isShowPinnedOfDashboardPage, value);
  }
}
