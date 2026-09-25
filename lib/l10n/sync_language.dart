import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/local_data_manager.dart';

enum SyncLanguage {
  chinese('zh', Locale('zh', 'CN')),
  english('en', Locale('en')),
  system('system', null);

  const SyncLanguage(this.storageValue, this.locale);
  final String storageValue;
  final Locale? locale;

  /// Missing/unknown preferences retain the existing Chinese default.
  static SyncLanguage fromStored(String? value) {
    final normalized = value?.replaceAll('_', '-').toLowerCase();
    if (normalized == 'system') return system;
    if (normalized == 'en' || normalized?.startsWith('en-') == true) {
      return english;
    }
    return chinese;
  }
}

/// Loaded once after local preferences initialize, before runApp.
final syncLanguageBootstrapProvider = Provider<SyncLanguage>(
  (ref) => SyncLanguage.chinese,
);

final syncLanguageWriterProvider = Provider<Future<void> Function(String)>(
  (ref) =>
      (value) =>
          LocalDataManager.instance.setString(AppKeys.languageCode, value),
);

final syncLanguageProvider =
    NotifierProvider<SyncLanguageController, SyncLanguage>(
      SyncLanguageController.new,
    );

class SyncLanguageController extends Notifier<SyncLanguage> {
  @override
  SyncLanguage build() => ref.watch(syncLanguageBootstrapProvider);

  Future<void> select(SyncLanguage language) async {
    await ref.read(syncLanguageWriterProvider)(language.storageValue);
    if (ref.mounted) state = language;
  }
}
