/// The connection notes must describe what the adapters really do.
///
/// The rows used to read like an internal feature matrix (“条件创建 / 范围下载 /
/// 安全存储密码”), including capabilities the app never uses (a cloud trash, a
/// ranged read) and a sentence that suggested resuming an upload on a protocol
/// that declares `supportsResumableUpload: false`.
library;

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/providers/provider_capability_summary.dart';
import 'package:velock_sync/providers/webdav/webdav_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

const _webDav = ProtocolModel.webDav(
  protocolType: WebDavProtocolType.https,
  address: 'https://dav.example.test',
  port: '443',
);

ProtocolModel _oauth(RemoteProviderType type) => ProtocolModel.oauth(
  providerType: type,
  clientId: 'public-client',
  credentialRef: 'opaque-ref',
  rootId: 'root',
);

final _cjk = RegExp(r'[\u4e00-\u9fff]');

void main() {
  group('providerCapabilitySummary', () {
    test('describes the WebDAV adapter in plain words', () {
      final summary = providerCapabilitySummary(_webDav, context: null);

      expect(summary.providerName, 'WebDAV');
      expect(summary.features.join('\n'), contains('原子改名'));
      expect(summary.features.join('\n'), contains('不会覆盖'));
      expect(summary.limitations.join('\n'), contains('不支持断点续传'));
      expect(summary.limitations.join('\n'), contains('真正能写入的文件夹'));
    });

    test('never names a protocol feature the app does not turn into words', () {
      final summaries = [
        providerCapabilitySummary(_webDav, context: null),
        providerCapabilitySummary(
          _oauth(RemoteProviderType.googleDrive),
          context: null,
        ),
        providerCapabilitySummary(
          _oauth(RemoteProviderType.oneDrive),
          context: null,
        ),
      ];
      for (final summary in summaries) {
        final prose = [...summary.features, ...summary.limitations].join('\n');
        // Jargon that told a user nothing, or a service feature the app never
        // calls: a cloud trash and a ranged read are not Sync features.
        for (final claim in ['条件创建', '范围下载', '回收站', '可恢复上传', 'Token Broker']) {
          expect(prose, isNot(contains(claim)), reason: '$claim in $prose');
        }
      }
    });

    test('does not overpromise WebDAV resumable upload', () {
      final store = WebDavObjectStore(
        dio: Dio(),
        baseUri: Uri.parse('https://dav.example.test'),
        username: 'user',
        password: 'secret',
      );
      expect(store.capabilities.supportsResumableUpload, isFalse);

      final summary = providerCapabilitySummary(_webDav, context: null);
      expect(summary.features.join('\n'), isNot(contains('续传')));
      expect(summary.limitations.join('\n'), contains('不支持断点续传'));
    });

    test('the cloud drives keep their own access limits', () {
      final drive = providerCapabilitySummary(
        _oauth(RemoteProviderType.googleDrive),
        context: null,
      );
      expect(drive.providerName, 'Google Drive');
      expect(drive.features.join('\n'), contains('PKCE'));
      expect(drive.features.join('\n'), contains('分片上传'));
      expect(drive.limitations.join('\n'), contains('授权给 Sync'));
      // Chunked upload is implemented; resuming an interrupted one is not.
      expect(drive.limitations.join('\n'), contains('重新开始'));

      final oneDrive = providerCapabilitySummary(
        _oauth(RemoteProviderType.oneDrive),
        context: null,
      );
      expect(oneDrive.providerName, 'OneDrive');
      expect(oneDrive.limitations.join('\n'), contains('Microsoft Graph'));
    });

    test('credentials are described, not sold as a connection feature', () {
      final summary = providerCapabilitySummary(_webDav, context: null);
      expect(summary.credentials, contains('系统安全存储'));
      expect(
        summary.features.any((feature) => feature.contains('安全存储')),
        isFalse,
      );
    });

    test('a cloud drive without an official component promises nothing', () {
      final summary = providerCapabilitySummary(
        _oauth(RemoteProviderType.aliyunDrive),
        context: null,
      );
      expect(summary.providerName, 'aliyunDrive');
      expect(summary.features, isEmpty);
      expect(summary.limitations.single, contains('还不能使用'));
      expect(summary.credentials, contains('不保存'));
    });

    testWidgets('every row is localized, so an English sheet stays English', (
      tester,
    ) async {
      final summaries = <ProviderCapabilitySummary>[];
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: const [
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: Builder(
            builder: (context) {
              summaries.addAll([
                providerCapabilitySummary(_webDav, context: context),
                providerCapabilitySummary(
                  _oauth(RemoteProviderType.googleDrive),
                  context: context,
                ),
                providerCapabilitySummary(
                  _oauth(RemoteProviderType.oneDrive),
                  context: context,
                ),
                providerCapabilitySummary(
                  _oauth(RemoteProviderType.aliyunDrive),
                  context: context,
                ),
              ]);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(
        summaries.expand((s) => s.features).toList(),
        contains('Browse, upload and download files on the service'),
      );
      for (final summary in summaries) {
        for (final text in [
          ...summary.features,
          ...summary.limitations,
          summary.credentials,
        ]) {
          expect(
            _cjk.hasMatch(text),
            isFalse,
            reason: 'en sheet paints Chinese: “$text”',
          );
        }
      }
    });
  });
}
