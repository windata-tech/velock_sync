/// Locale sweep for the failure copy a user reads.
///
/// The plain folder domain and the Velock backup domain share one rule: the
/// sentence is presented through `syncText`, so every code must have a real
/// English sentence and must never leak Chinese into an English build. The
/// codes themselves are the contract from `plain_failure_cases.dart`.
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/widgets/app_format.dart';

import '../features/plain_sync/plain_failure_cases.dart';

final _han = RegExp(r'[\u4e00-\u9fff]');

List<FailureProbe> get _probes => [
  for (final failure in plainFailureCases)
    (code: failure.code, connectionName: failure.connectionName),
];

/// Renders [AppFormat.errorSummary] inside its own keyed tree, for the same
/// reason [renderPlainFailures] mounts one: a context kept from an earlier pump
/// resolves the new locale.
Future<String> _errorSummary(
  WidgetTester tester,
  Locale locale,
  String? code,
) async {
  late String rendered;
  await tester.pumpWidget(
    MaterialApp(
      key: ValueKey('app-format-${locale.languageCode}'),
      locale: locale,
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Builder(
        builder: (context) {
          rendered = AppFormat.errorSummary(code, context: context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return rendered;
}

void main() {
  testWidgets('every plain failure code has a real English sentence', (
    tester,
  ) async {
    final rendered = await renderPlainFailures(
      tester,
      const Locale('en'),
      _probes,
    );

    for (var index = 0; index < plainFailureCases.length; index++) {
      final failure = plainFailureCases[index];
      expect(rendered[index].trim(), isNotEmpty, reason: failure.code);
      expect(rendered[index], failure.en, reason: failure.code);
      expect(rendered[index], isNot(matches(_han)), reason: failure.code);
    }
  });

  testWidgets('every plain failure code has a Chinese sentence that differs', (
    tester,
  ) async {
    final rendered = await renderPlainFailures(
      tester,
      const Locale('zh'),
      _probes,
    );

    for (var index = 0; index < plainFailureCases.length; index++) {
      final failure = plainFailureCases[index];
      expect(rendered[index], failure.zh, reason: failure.code);
      expect(rendered[index], isNot(failure.en), reason: failure.code);
      expect(
        _han.hasMatch(rendered[index]),
        isTrue,
        reason: '${failure.code} must stay Chinese in a Chinese build',
      );
    }
  });

  testWidgets('the unknown-code sentence is localized too', (tester) async {
    expect(
      await renderPlainFailure(tester, const Locale('zh'), 'future.unknown'),
      unknownPlainFailureZh,
    );
    expect(
      await renderPlainFailure(tester, const Locale('en'), 'future.unknown'),
      unknownPlainFailureEn,
    );
  });

  testWidgets('Velock backup says to free cloud space for a full drive', (
    tester,
  ) async {
    // 507 is what a provider returns when the cloud drive cannot take the write.
    // The stored suggested action says to free space, so the visible sentence
    // must say the same thing instead of the generic "try again later".
    expect(
      await _errorSummary(tester, const Locale('zh'), 'provider.http.507'),
      '云端空间不足，请清理云端文件或扩容后重试。',
    );
    expect(
      await _errorSummary(tester, const Locale('en'), 'provider.http.507'),
      'The cloud drive is out of space. Free up space or add more, then try again.',
    );
    expect(
      await _errorSummary(tester, const Locale('zh'), 'provider.http.507'),
      isNot('同步未完成，请稍后重试。'),
    );
  });

  testWidgets('Velock backup names a missing network as a missing network', (
    tester,
  ) async {
    expect(
      await _errorSummary(tester, const Locale('zh'), 'network.offline'),
      '没有网络连接，连上网络后再试。',
    );
    expect(
      await _errorSummary(tester, const Locale('en'), 'network.offline'),
      'There is no network connection. Connect to the internet and try again.',
    );
  });

  testWidgets('an unknown code stays a plain sentence in Velock too', (
    tester,
  ) async {
    for (final code in const [
      'sync.unexpected',
      'future.unknown_code',
      'provider.http.507',
    ]) {
      final message = await _errorSummary(tester, const Locale('zh'), code);
      expect(message, isNot(contains(code)), reason: code);
      expect(_han.hasMatch(message), isTrue, reason: code);
    }
  });
}
