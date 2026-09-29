import 'package:material_ui/material_ui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'sync_language.dart';
import 'sync_locale.dart';

/// Always available, even if loading the unrelated sync settings fails.
class _SyncLanguageChoices extends ConsumerStatefulWidget {
  const _SyncLanguageChoices();

  @override
  ConsumerState<_SyncLanguageChoices> createState() =>
      _SyncLanguageSettingState();
}

class _SyncLanguageSettingState extends ConsumerState<_SyncLanguageChoices> {
  bool _saving = false;
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(syncLanguageProvider);
    return AdaptiveListSection(
      header: syncText(context, '语言', 'Language'),
      footer: _failed
          ? Text(
              syncText(
                context,
                '无法保存语言设置，请重试。',
                'Could not save the language. Please try again.',
              ),
            )
          : null,
      children: [
        for (final language in SyncLanguage.values)
          AdaptiveListTile(
            widgetKey: Key('sync-language-${language.storageValue}'),
            title: Text(switch (language) {
              SyncLanguage.chinese => '简体中文',
              SyncLanguage.english => 'English',
              SyncLanguage.system => syncText(context, '跟随系统', 'Follow system'),
            }),
            trailing: selected == language ? const Icon(Icons.check) : null,
            enabled: !_saving,
            onTap: _saving
                ? null
                : () async {
                    setState(() {
                      _saving = true;
                      _failed = false;
                    });
                    try {
                      await ref
                          .read(syncLanguageProvider.notifier)
                          .select(language);
                    } on Object {
                      if (mounted) setState(() => _failed = true);
                    } finally {
                      if (mounted) setState(() => _saving = false);
                    }
                  },
          ),
      ],
    );
  }
}

/// Stable navigation entry, independent of remote connections and sync loading.
class SyncLanguageSetting extends ConsumerWidget {
  const SyncLanguageSetting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(syncLanguageProvider);
    return AdaptiveListSection(
      children: [
        AdaptiveListTile(
          widgetKey: const Key('sync-language-setting'),
          title: Text(syncText(context, '语言', 'Language')),
          subtitle: Text(switch (selected) {
            SyncLanguage.chinese => '简体中文',
            SyncLanguage.english => 'English',
            SyncLanguage.system => syncText(context, '跟随系统', 'Follow system'),
          }),
          showChevron: true,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (context) => const SyncLanguagePage(),
            ),
          ),
        ),
      ],
    );
  }
}

class SyncLanguagePage extends StatelessWidget {
  const SyncLanguagePage({super.key});

  @override
  Widget build(BuildContext context) => AdaptiveScaffold(
    title: syncText(context, '语言', 'Language'),
    body: ListView(children: const [_SyncLanguageChoices()]),
  );
}
